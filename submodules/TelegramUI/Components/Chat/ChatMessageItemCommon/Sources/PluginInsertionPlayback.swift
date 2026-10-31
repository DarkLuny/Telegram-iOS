import Foundation
import UIKit
import Display
import TelegramCore

/// Plays a plugin-described appearance animation on a row.
///
/// A plugin answers "how should this row appear" with numbers — a start scale, a
/// start offset, a rotation, a duration, a curve. This file turns those numbers
/// into Core Animation calls so neither the plugin runtime nor the individual row
/// classes have to know how a transform is built on iOS.
///
/// The whole animation is applied to one layer as a single `transform`
/// animation. That matters: the Android original set `translationX`, `scaleX`,
/// `rotation` and `rotationY` as separate view properties and animated them
/// together, and Core Animation does not compose four independent animations on
/// one property into the same result — the outcome depends on which animation
/// starts first. One matrix has one result.
public enum PluginInsertionPlayback {
    /// Converts a plugin animation into the two matrices to interpolate.
    ///
    /// The matrix order is translate ∘ rotate ∘ scale, so the row spins and
    /// scales about its own centre and is then carried by the offset. `m34`
    /// gives the 3D rotations their perspective; without it a flip about X or Y
    /// reads as a flat squash instead of the tilt the style asks for.
    public static func transform(from animation: PluginInsertionAnimation) -> (from: CATransform3D, to: CATransform3D) {
        let perspective = 1.0 / 1200.0
        var from = CATransform3DIdentity
        from.m34 = -perspective
        from = CATransform3DTranslate(from, CGFloat(animation.translationX), CGFloat(animation.translationY), 0.0)
        from = CATransform3DRotate(from, radians(animation.rotationZ), 0.0, 0.0, 1.0)
        from = CATransform3DRotate(from, radians(animation.rotationY), 0.0, 1.0, 0.0)
        from = CATransform3DRotate(from, radians(animation.rotationX), 1.0, 0.0, 0.0)
        from = CATransform3DScale(from, CGFloat(animation.scaleFromX), CGFloat(animation.scaleFromY), 1.0)

        var to = CATransform3DIdentity
        to.m34 = -perspective
        to = CATransform3DScale(to, CGFloat(animation.scaleToX), CGFloat(animation.scaleToY), 1.0)
        return (from, to)
    }

    /// The Core Animation timing function for a plugin curve.
    ///
    /// `overshoot` becomes a damped spring rather than a timing function: the
    /// only ease curves Core Animation ships with are monotonic, so nothing in
    /// its name list can overshoot. The plugin's tension is mapped onto damping —
    /// more tension, less damping, more overshoot.
    public static func timingFunction(_ curve: PluginInsertionAnimation.Curve, overshoot: Double) -> String {
        switch curve {
        case .linear:
            return CAMediaTimingFunctionName.linear.rawValue
        case .decelerate:
            return CAMediaTimingFunctionName.easeOut.rawValue
        case .accelerate:
            return CAMediaTimingFunctionName.easeIn.rawValue
        case .accelerateDecelerate:
            return CAMediaTimingFunctionName.easeInEaseOut.rawValue
        case .spring:
            return kCAMediaTimingFunctionSpring
        case .overshoot:
            // Mass 1, stiffness 260: the critical damping for that stiffness is
            // 2·√260 ≈ 32, so anything below it overshoots at all. The tension
            // range the plugin uses is roughly 1.0 … 2.7.
            let tension = max(1.0, overshoot)
            let damping = max(9.0, 27.0 - (tension - 1.0) * 10.0)
            return "\(kCAMediaTimingFunctionCustomSpringPrefix)_1_260_\(String(format: "%.1f", damping))_0"
        }
    }

    /// Applies `animation` to `layer`, overriding the stock insertion animation.
    ///
    /// Returns `false` when there is nothing to play, so the caller can fall back
    /// to the stock appearance.
    @discardableResult
    public static func apply(_ animation: PluginInsertionAnimation, to layer: CALayer, alpha: CGFloat = 1.0) -> Bool {
        let duration = animation.duration / 1000.0
        guard duration > 0.0 else {
            return false
        }
        let delay = max(0.0, animation.delay / 1000.0)
        let timing = timingFunction(animation.curve, overshoot: animation.overshoot)

        if let keyframes = animation.rotationKeyframes, keyframes.count >= 2 {
            // A wobble draws a path, not a straight line: one keyframed matrix
            // walks the whole curve, with the offset shrinking across the same
            // steps so the row settles into place at the end.
            var values: [AnyObject] = []
            let count = keyframes.count
            for index in 0 ..< count {
                let progress = CGFloat(index) / CGFloat(count - 1)
                var transform = CATransform3DIdentity
                transform.m34 = -1.0 / 1200.0
                transform = CATransform3DTranslate(
                    transform,
                    CGFloat(animation.translationX) * (1.0 - progress),
                    CGFloat(animation.translationY) * (1.0 - progress),
                    0.0
                )
                transform = CATransform3DRotate(transform, radians(keyframes[index]), 0.0, 0.0, 1.0)
                let scale = CGFloat(animation.scaleFromX) + (CGFloat(animation.scaleToX) - CGFloat(animation.scaleFromX)) * progress
                transform = CATransform3DScale(transform, scale, scale, 1.0)
                values.append(NSValue(caTransform3D: transform))
            }
            layer.animateKeyframes(
                values: values,
                duration: duration,
                keyPath: "transform",
                timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue,
                removeOnCompletion: false
            )
        } else {
            let matrices = transform(from: animation)
            layer.animateTransform(
                from: matrices.from,
                to: matrices.to,
                duration: duration,
                delay: delay,
                timingFunction: timing,
                removeOnCompletion: false
            )
        }

        if animation.alphaFrom < 1.0 {
            layer.animateAlpha(from: CGFloat(animation.alphaFrom) * alpha, to: alpha, duration: duration, delay: delay, timingFunction: timing)
        }
        return true
    }

    /// Asks the plugins how this row should appear, and plays the answer.
    ///
    /// `message` is `nil` for a date separator, which the plugin receives as a
    /// `null` payload. `size` is the row's laid-out size, which the styles that
    /// slide in "from the bottom" measure their offset against; a zero size falls
    /// back to a typical bubble so the motion still reads.
    @discardableResult
    public static func play(
        layer: CALayer,
        accountId: Int64,
        message: EngineRawMessage?,
        isDate: Bool,
        size: CGSize
    ) -> Bool {
        guard let hook = PluginHookPoints.shared.insertionAnimation else {
            return false
        }
        let payload = message.map { pluginMessageDetailsJSON($0) } ?? "null"
        let width = size.width > 2.0 ? Double(size.width) : 540.0
        let height = size.height > 2.0 ? Double(size.height) : 220.0
        guard let animation = hook(accountId, payload, isDate, width, height) else {
            return false
        }
        return apply(animation, to: layer)
    }

    private static func radians(_ degrees: Double) -> CGFloat {
        return CGFloat(degrees) * .pi / 180.0
    }
}