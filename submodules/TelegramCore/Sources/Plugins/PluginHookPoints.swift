import Foundation
import SwiftSignalKit
import MtProtoKit
// Same access level the rest of TelegramCore uses, and all that is needed here:
// no `Api.*` type appears in this file's public surface, only TL values passed
// as `Any` and turned into JSON.
internal import TelegramApi

/// Hook points the plugin runtime attaches to, declared inside TelegramCore so the
/// core does not depend on the plugin module.
///
/// The dependency direction matters: `ExteraPluginKit` needs `AccountContext`, and
/// `AccountContext` needs `TelegramCore`. A direct reference from the core to the
/// plugin runtime would be a cycle. Instead the core exposes these closures and
/// the app wires them up at launch; when nothing is wired every hook is `nil` and
/// the cost is one optional check.
///
/// Arguments cross these closures as JSON text, never as object graphs. A TL
/// request's parameters contain Swift enums and `TLObject`s that
/// `JSONSerialization` refuses, so they are flattened by
/// `pluginRequestParametersJSON` before they get here.
public final class PluginHookPoints {
    public static let shared = PluginHookPoints()

    /// Called before an outgoing message is enqueued. `text` may be rewritten in
    /// place; returning `false` cancels the send.
    ///
    /// Mirrors exteraGram's `on_send_message_hook`, which can both replace the
    /// message and drop it.
    public var sendMessage: ((_ accountId: Int64, _ peerId: Int64, _ text: inout String) -> Bool)?

    /// Whether a plugin listens for this request name (`messages.setTyping`).
    ///
    /// Checked before the parameters are flattened: a build with no plugins must
    /// not pay for building a JSON document on every request, and the flattening
    /// walks every parameter of every TL call. `nil` means nothing intercepts
    /// requests at all.
    public var wantsRequest: ((_ name: String) -> Bool)?

    /// Called before a TL request leaves the device, with the request's parameters
    /// as a JSON object. Returning `false` cancels the request.
    ///
    /// `name` is the schema constructor name with dots (`messages.setTyping`), the
    /// identifier exteraGram's `pre_request_hook` receives.
    public var preRequest: ((_ name: String, _ accountId: Int64, _ parametersJSON: String) -> Bool)?

    /// Called after a TL request finished, whether it succeeded or failed.
    ///
    /// `responseJSON` is the flattened result (constructor fields, like a
    /// request's parameters) and is `"{}"` for a failed call; `error` is the
    /// server's description when there was one. exteraGram's
    /// `post_request_hook(name, account, response, error)` maps onto this.
    public var postRequest: ((_ name: String, _ accountId: Int64, _ responseJSON: String, _ error: String?) -> Void)?

    /// Called for every update the account state receives. `name` is the update's
    /// constructor (`updateNewMessage`), which is what exteraGram's
    /// `on_update_hook` is matched against; `updateJSON` flattens its fields the
    /// same way a request's parameters are flattened.
    ///
    /// Unlike a request hook this cannot cancel or rewrite anything: the update
    /// has already been accepted, and a plugin only observes it.
    public var receivedUpdate: ((_ accountId: Int64, _ name: String, _ updateJSON: String) -> Void)?

    /// Called once per received batch, for plugins that subscribed to `*`. The
    /// JSON is `{"updates": [{"name": ..., "fields": {...}}, ...]}`.
    public var receivedUpdates: ((_ accountId: Int64, _ batchJSON: String) -> Void)?

    /// Whether any plugin cares about an update constructor. Checked before the
    /// fields are flattened, because describing an update is far more expensive
    /// than comparing a name, and app with no plugins should pay neither.
    public var wantsUpdate: ((_ name: String) -> Bool)?

    /// Messages the client is about to delete locally, as `{"messages": [...]}`
    /// with one `pluginMessageDetailsJSON` object per message.
    ///
    /// A delete the *server* performs arrives as `updateDeleteMessages`, and the
    /// plugin has already seen the message through `updateNewMessage`, so it can
    /// mark it. Deleting a message the user wrote himself is different: the
    /// client sends `messages.deleteMessages`, the server answers with
    /// `affectedMessages` and the client removes the row itself, so no
    /// `updateDeleteMessages` is ever delivered. The message also never arrived
    /// as `updateNewMessage` — sending it from this device answers
    /// `updateShortSentMessage`, of which only the `pts` is applied — so the
    /// plugin has neither the text nor the delete.
    ///
    /// This hook closes that gap at the only point where both facts still exist:
    /// immediately before the local delete, while the message is in the store.
    /// It is the iOS equivalent of the Android module's `DeleteMessages` /
    /// `MarkMessagesAsDeletedInternal` hooks, which stored the message the same
    /// way. Like the update hooks it is observational: the delete happens either
    /// way.
    public var messagesWillBeDeleted: ((_ accountId: Int64, _ messagesJSON: String) -> Void)?

    /// Whether any plugin implements `messagesWillBeDeleted`'s callback.
    ///
    /// Asked once per delete, before the messages are encoded, for the same
    /// reason as `wantsHideMessage`: describing a message walks its attributes
    /// and media, and an app with no plugin listening should not pay for it on a
    /// path the user did not ask for. `nil` means nothing asks at all.
    public var wantsMessagesWillBeDeleted: (() -> Bool)?

    /// Messages a plugin kept after they were deleted, for one chat.
    ///
    /// A message the user deletes is erased from the database, so the row is
    /// rebuilt here from the copy the plugin stored. `peerId` is Postbox's
    /// `PeerId.toInt64()`, the same number `pluginMessageDetailsJSON` reports as
    /// `peer_id`, and the answer is the rows that still belong in the chat,
    /// oldest first.
    ///
    /// The rows are not in the database: they exist only in the list, which is
    /// why the entries carrying them are marked `isDeleted` and the date/status
    /// node draws the marker. `nil` means nothing keeps copies at all.
    public var deletedMessages: ((_ accountId: Int64, _ peerId: Int64) -> [PluginStoredMessage])?

    /// Whether any plugin keeps deleted messages for a chat.
    ///
    /// Asked once per history view, before the row loop, for the same reason as
    /// `wantsHideMessage`: a plugin that keeps nothing must not cost a script
    /// call on every chat the user opens.
    public var wantsDeletedMessages: (() -> Bool)?

    // MARK: - Appearance
    //
    // The four hooks below are not network interception: they answer "what should
    // this look like" while the app builds a screen. A plugin on Android reached
    // the same effect by hooking an obfuscated cell and driving an `ObjectAnimator`
    // or rewriting a colour table; iOS has neither surface, so the questions are
    // asked directly and answered with values. Every one of them returns `nil`
    // for "leave the stock appearance alone", which is what an app with no
    // plugins does.

    /// Keys the attachment menu must not offer, e.g. `["gallery", "app_shortcut"]`.
    ///
    /// The argument is the list the app was about to show, so the plugin answers
    /// with the same identifiers it was given instead of translating Android button
    /// ids. The answer is the subset to keep; a key that was not offered is
    /// ignored by the caller, so a plugin cannot hide something it never saw.
    public var attachMenuExclusions: ((_ accountId: Int64, _ peerId: Int64?, _ keys: [String]) -> [String])?

    /// Rows of the settings tab the plugin wants hidden, e.g. `["premium", "stars"]`.
    ///
    /// Same shape as the attach menu: the caller passes the identifiers it was
    /// about to show, and the answer is the subset to keep. On Android this was a
    /// hook on the settings list adapter; here the screen asks once while it is
    /// being built, so a hidden row is never created and the section is not left
    /// with a gap. A key that was not offered is ignored, so a plugin cannot hide
    /// something it never saw.
    public var settingsRowExclusions: ((_ accountId: Int64, _ keys: [String]) -> [String])?

    /// How a row should appear: descriptors for its transform, opacity and timing.
    ///
    /// `messageJSON` is `pluginMessageDetailsJSON` output for a message row, and
    /// an empty object for a date separator. The plugin computes the numbers
    /// because the style, speed and per-chat randomness all come from its settings;
    /// the app only plays the animation.
    public var insertionAnimation: ((_ accountId: Int64, _ messageJSON: String, _ isDate: Bool, _ width: Double, _ height: Double) -> PluginInsertionAnimation?)?

    /// The colour a plugin wants every peer name painted with.
    ///
    /// The palette is built once per account and then reused by every name, avatar
    /// and ring in the app, so replacing it here reaches all of them at once.
    public var nameColors: ((_ accountId: Int64?) -> PluginNameColorsOverride?)?

    /// Whether a plugin wants this message hidden from a chat history list.
    ///
    /// The Android module hid a message by rewriting the list adapter's array
    /// (`FilterShadowbannedDialogs`, the regex filters and its shadowban cache).
    /// iOS draws a list from `ChatHistoryEntry` values, so the equivalent is to
    /// drop an entry before it reaches the list. `messageJSON` is
    /// `pluginMessageDetailsJSON` output, which is where `sender_id`, `peer_id`
    /// and `text` come from.
    ///
    /// `true` means "do not draw this row". The message is still in the database
    /// and still in the original view; only the row is hidden, exactly as the
    /// Android module left the message where it was and hid it from the list.
    public var hideMessage: ((_ accountId: Int64, _ messageJSON: String) -> Bool)?

    /// Whether any plugin implements `on_hide_message`.
    ///
    /// Asked once per history view, before the row loop: `hideMessage` takes an
    /// already-encoded message, and encoding every visible message only to hear
    /// "no plugin listens" would put a JSON document per row on the list's
    /// build path. `nil` (nothing wired) and `false` both mean "stock list".
    public var wantsHideMessage: (() -> Bool)?

    /// Rows of a "message details" screen for `messageJSON`.
    ///
    /// Empty means the plugin has nothing to add, and no menu item appears.
    public var messageDetails: ((_ accountId: Int64, _ messageJSON: String) -> [PluginDetailItem])?

    /// The accent colour a plugin wants the whole interface painted with.
    ///
    /// Separate from `nameColors` because it changes a different thing: name
    /// colours are a per-peer palette, while the accent drives buttons, links,
    /// selections, badges and the outgoing bubble. A plugin that recolours the
    /// interface speaks here; one that only recolours names does not.
    public var themeOverride: ((_ accountId: Int64?) -> PluginThemeOverride?)?

    /// Fires when a plugin changed something the UI has already drawn.
    ///
    /// A colour override is read once per account, when the palette is built; a
    /// plugin that changes its colour later has no way to reach the palette it
    /// already produced. This signal is how it asks for a rebuild. The palette
    /// lives in `AccountContext`, which already depends on this module, so the
    /// notification belongs here too rather than in a new import on the UI side.
    private let appearanceChangedPipe = ValuePipe<Void>()

    public var appearanceChanged: Signal<Void, NoError> {
        return self.appearanceChangedPipe.signal()
    }

    /// Called by the plugin runtime after a setting that affects appearance
    /// changed. Cheaper than rebuilding on every setting: a plugin that only
    /// touched a toggle nobody draws is not worth a palette rebuild.
    public func notifyAppearanceChanged() {
        self.appearanceChangedPipe.putNext(Void())
    }

    private init() {
    }
}

/// One row of a plugin-provided details screen.
public struct PluginDetailItem {
    public let title: String
    public let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }
}

/// A message a plugin kept after it was deleted.
///
/// Everything here comes from the plugin's own storage rather than from the
/// database: the message is gone, so the row in the chat has to be built from
/// this description alone. That is why the text is a plain string with no
/// entities and no media — the plugin only kept what it could encode into its
/// JSON file, and a row that pretends to have more than that would show a
/// message that never existed.
public struct PluginStoredMessage {
    /// The peer the message belongs to, as `PeerId.toInt64()`.
    public let peerId: Int64
    /// The original message id, which is what makes the row stable across
    /// rebuilds of the list and keeps a scroll position from jumping.
    public let messageId: Int32
    public let timestamp: Int32
    public let text: String
    /// What kind of media the message had, when it had no text.
    ///
    /// The plugin kept a marker rather than the file itself — it can only store
    /// what fits in its JSON file — so a deleted photo cannot be shown again.
    /// Pretending otherwise, with an empty bubble, would read as a message that
    /// was never sent; the marker says "there was a photo here", which is what
    /// the module's own deleted-messages screen showed too.
    public let mediaKind: String?
    /// The author, when the plugin kept one. `nil` for a message with no author
    /// (a channel post, a deleted account).
    public let senderId: Int64?
    public let isOutgoing: Bool

    public init(peerId: Int64, messageId: Int32, timestamp: Int32, text: String, mediaKind: String?, senderId: Int64?, isOutgoing: Bool) {
        self.peerId = peerId
        self.messageId = messageId
        self.timestamp = timestamp
        self.text = text
        self.mediaKind = mediaKind
        self.senderId = senderId
        self.isOutgoing = isOutgoing
    }
}

/// A row-appearance animation, already resolved to numbers.
///
/// The plugin decides the style; this type carries the result so the UI layer
/// needs no knowledge of the plugin's settings. Distances are points, angles are
/// degrees, `duration` and `delay` are milliseconds.
public struct PluginInsertionAnimation {
    /// Curve to apply. `overshoot` needs `overshoot` to be non-zero, `spring`
    /// uses the layer's own spring timing.
    public enum Curve: String {
        case linear
        case decelerate
        case accelerate
        case accelerateDecelerate
        case overshoot
        case spring
    }

    public var duration: Double
    public var delay: Double
    public var alphaFrom: Double
    public var scaleFromX: Double
    public var scaleFromY: Double
    public var scaleToX: Double
    public var scaleToY: Double
    public var translationX: Double
    public var translationY: Double
    public var rotationZ: Double
    public var rotationX: Double
    public var rotationY: Double
    public var curve: Curve
    public var overshoot: Double
    /// Extra rotation steps for styles that wobble. When present these replace
    /// `rotationZ` as a keyframe path that starts and ends at zero.
    public var rotationKeyframes: [Double]?

    public init(
        duration: Double,
        delay: Double = 0.0,
        alphaFrom: Double = 0.0,
        scaleFromX: Double = 1.0,
        scaleFromY: Double = 1.0,
        scaleToX: Double = 1.0,
        scaleToY: Double = 1.0,
        translationX: Double = 0.0,
        translationY: Double = 0.0,
        rotationZ: Double = 0.0,
        rotationX: Double = 0.0,
        rotationY: Double = 0.0,
        curve: Curve = .decelerate,
        overshoot: Double = 0.0,
        rotationKeyframes: [Double]? = nil
    ) {
        self.duration = duration
        self.delay = delay
        self.alphaFrom = alphaFrom
        self.scaleFromX = scaleFromX
        self.scaleFromY = scaleFromY
        self.scaleToX = scaleToX
        self.scaleToY = scaleToY
        self.translationX = translationX
        self.translationY = translationY
        self.rotationZ = rotationZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.curve = curve
        self.overshoot = overshoot
        self.rotationKeyframes = rotationKeyframes
    }

    /// Builds the animation from the JSON a plugin returned.
    ///
    /// Every field is optional, so a style can describe only what it changes:
    /// a plain fade sends `{"alpha": 0, "duration": 400}` and gets the stock
    /// scale. The curve is a string name; an unknown one falls back to
    /// `decelerate` rather than failing the whole animation.
    public init?(json: [String: Any]) {
        guard let duration = (json["duration"] as? NSNumber)?.doubleValue else {
            return nil
        }
        func number(_ key: String, _ fallback: Double) -> Double {
            return (json[key] as? NSNumber)?.doubleValue ?? fallback
        }
        var keyframes: [Double]?
        if let list = json["rotationKeyframes"] as? [Any] {
            keyframes = list.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        self.init(
            duration: duration,
            delay: number("delay", 0.0),
            alphaFrom: number("alpha", 1.0),
            scaleFromX: number("scaleX", 1.0),
            scaleFromY: number("scaleY", 1.0),
            scaleToX: number("scaleToX", 1.0),
            scaleToY: number("scaleToY", 1.0),
            translationX: number("translationX", 0.0),
            translationY: number("translationY", 0.0),
            rotationZ: number("rotationZ", 0.0),
            rotationX: number("rotationX", 0.0),
            rotationY: number("rotationY", 0.0),
            curve: Curve(rawValue: (json["curve"] as? String) ?? "decelerate") ?? .decelerate,
            overshoot: number("overshoot", 0.0),
            rotationKeyframes: keyframes
        )
    }
}

/// A replacement palette, in `0xRRGGBB` form.
///
/// `secondary` is the gradient partner: a plugin with the gradient switch off
/// leaves it `nil`, and the app then paints a single flat colour.
public struct PluginNameColorsOverride {
    public var main: UInt32
    public var secondary: UInt32?
    public var applyToNames: Bool
    public var applyToAvatars: Bool
    public var applyToStories: Bool
    public var applyToDialogs: Bool
    public var applyToProfiles: Bool

    public init(
        main: UInt32,
        secondary: UInt32? = nil,
        applyToNames: Bool = true,
        applyToAvatars: Bool = true,
        applyToStories: Bool = true,
        applyToDialogs: Bool = true,
        applyToProfiles: Bool = true
    ) {
        self.main = main
        self.secondary = secondary
        self.applyToNames = applyToNames
        self.applyToAvatars = applyToAvatars
        self.applyToStories = applyToStories
        self.applyToDialogs = applyToDialogs
        self.applyToProfiles = applyToProfiles
    }

    /// The palette with every entry replaced, keeping its keys and order.
    ///
    /// A gradient pair is what `PeerNameColors.Colors` can express; a plugin that
    /// turned the gradient off gets one colour and `nil` for the other two.
    public func replacing(_ source: [Int32: [UInt32]]) -> [Int32: [UInt32]] {
        var result: [Int32: [UInt32]] = [:]
        for (key, _) in source {
            if let secondary = self.secondary {
                result[key] = [self.main, secondary, self.main]
            } else {
                result[key] = [self.main]
            }
        }
        return result
    }

    /// Builds the override from the JSON a plugin returned.
    ///
    /// `main` is required and in `0xRRGGBB`; the alpha byte is dropped because a
    /// name colour is always opaque. A missing `secondary` means "no gradient",
    /// which is exactly what the plugin's own gradient switch turns off.
    public init?(json: [String: Any]) {
        guard let mainNumber = json["main"] as? NSNumber else {
            return nil
        }
        func flag(_ key: String) -> Bool {
            // An absent switch means "on": the plugin only sends the flags it
            // found in its settings, and leaving one out must not disable it.
            return (json[key] as? NSNumber)?.boolValue ?? true
        }
        var secondary: UInt32?
        if let secondaryNumber = json["secondary"] as? NSNumber {
            secondary = UInt32(truncatingIfNeeded: secondaryNumber.int64Value) & 0xFFFFFF
        }
        self.init(
            main: UInt32(truncatingIfNeeded: mainNumber.int64Value) & 0xFFFFFF,
            secondary: secondary,
            applyToNames: flag("names"),
            applyToAvatars: flag("avatars"),
            applyToStories: flag("stories"),
            applyToDialogs: flag("dialogs"),
            applyToProfiles: flag("profiles")
        )
    }
}

/// A replacement accent and background, in `0xRRGGBB` form.
///
/// This is the whole-interface counterpart of `PluginNameColorsOverride`: the
/// five switches a plugin exposes ("avatars", "names", ...) decide which pieces
/// of the palette it repaints, and this decides the colour they are repainted
/// with and how the theme itself is tinted.
///
/// `outgoingBubble` is optional on purpose. With it set, sent messages are
/// painted in the plugin's colour; without it the account keeps the bubble
/// colours its theme already had, which is what a user who only asked for a
/// coloured interface expects to keep.
public struct PluginThemeOverride {
    public var main: UInt32
    public var secondary: UInt32?
    public var outgoingBubble: UInt32?
    public var applyToNames: Bool
    public var applyToAvatars: Bool
    public var applyToStories: Bool
    public var applyToDialogs: Bool
    public var applyToProfiles: Bool

    public init(
        main: UInt32,
        secondary: UInt32? = nil,
        outgoingBubble: UInt32? = nil,
        applyToNames: Bool = true,
        applyToAvatars: Bool = true,
        applyToStories: Bool = true,
        applyToDialogs: Bool = true,
        applyToProfiles: Bool = true
    ) {
        self.main = main
        self.secondary = secondary
        self.outgoingBubble = outgoingBubble
        self.applyToNames = applyToNames
        self.applyToAvatars = applyToAvatars
        self.applyToStories = applyToStories
        self.applyToDialogs = applyToDialogs
        self.applyToProfiles = applyToProfiles
    }

    /// The accent's two bubble endpoints, or `nil` to keep the theme's own.
    ///
    /// Two entries is what a theme's bubble gradient uses: the first is the
    /// lighter end Telegram derives its own tints from, so both ends are the
    /// plugin's colour and only the derived tints differ. The conversion to
    /// `UIColor` happens where the colours are used, so this module stays free
    /// of a UI dependency for a value type.
    public var bubbleColors: [UInt32]? {
        guard let outgoingBubble = self.outgoingBubble else {
            return nil
        }
        return [outgoingBubble, outgoingBubble]
    }

    /// Builds the override from the JSON a plugin returned.
    ///
    /// `main` is required and in `0xRRGGBB`. A missing `secondary` means "no
    /// gradient", matching `PluginNameColorsOverride`; a missing `outgoing`
    /// means "keep the bubble colours the theme already uses".
    public init?(json: [String: Any]) {
        guard let mainNumber = json["main"] as? NSNumber else {
            return nil
        }
        func flag(_ key: String) -> Bool {
            return (json[key] as? NSNumber)?.boolValue ?? true
        }
        var secondary: UInt32?
        if let number = json["secondary"] as? NSNumber {
            secondary = UInt32(truncatingIfNeeded: number.int64Value) & 0xFFFFFF
        }
        var outgoing: UInt32?
        if let number = json["outgoing"] as? NSNumber {
            outgoing = UInt32(truncatingIfNeeded: number.int64Value) & 0xFFFFFF
        }
        self.init(
            main: UInt32(truncatingIfNeeded: mainNumber.int64Value) & 0xFFFFFF,
            secondary: secondary,
            outgoingBubble: outgoing,
            applyToNames: flag("names"),
            applyToAvatars: flag("avatars"),
            applyToStories: flag("stories"),
            applyToDialogs: flag("dialogs"),
            applyToProfiles: flag("profiles")
        )
    }

    /// The same flags as a name-colour override, so one plugin answer can drive
    /// both hooks without repeating itself.
    public var nameColors: PluginNameColorsOverride {
        return PluginNameColorsOverride(
            main: self.main,
            secondary: self.secondary,
            applyToNames: self.applyToNames,
            applyToAvatars: self.applyToAvatars,
            applyToStories: self.applyToStories,
            applyToDialogs: self.applyToDialogs,
            applyToProfiles: self.applyToProfiles
        )
    }
}

/// A request was cancelled by a plugin. Reported to the caller as an ordinary
/// error, because every call site already handles `MTRpcError`.
public let pluginCancelledRequestError: MTRpcError = MTRpcError(errorCode: 406, errorDescription: "PLUGIN_CANCELLED")

/// Flattens TL request parameters into something `JSONSerialization` accepts.
///
/// Primitives pass through, `Api.Bool` becomes a real `true`/`false`, and a nested
/// TL value becomes an object of its fields (`{"_": "peerUser", "user_id": ...}`).
/// The field form is what a ported exteraGram plugin expects: the Android runtime
/// hands its hooks TL objects, and code such as "remember this message before it
/// is deleted" reads `message.peer_id` and `message.id` off them. The constructor
/// name alone is not enough for any of that, and it is still available as `_`.
func pluginRequestParametersJSON(_ parameters: [(String, ConstructorParameterDescription)]) -> String {
    var result: [String: Any] = [:]
    for (name, description) in parameters {
        result[name] = pluginJSONValue(description.value)
    }
    return pluginJSONString(result)
}

private func pluginJSONValue(_ value: Any?, depth: Int = 0) -> Any {
    switch value {
    case nil, is NSNull:
        return NSNull()
    case let value as String:
        return value
    // Checked before the TL-object branch: `Api.Bool` is a TL constructor whose
    // values describe themselves as `boolTrue` / `boolFalse` (see TLObjectSupport),
    // but a plugin's `request.offline` has to be a real boolean. exteraGram passes
    // Python's `True`/`False` there, and a ghost mode tests `offline is True`:
    // handing it the string "boolFalse" made `account.updateStatus(offline=false)`
    // look like an offline call, so the ghost cancelled going online *and* going
    // offline, and the user stayed visibly online forever.
    case let value as Bool:
        return value
    case let value as Int:
        return value
    case let value as Int32:
        return Int(value)
    case let value as Int64:
        return value
    case let value as Double:
        return value
    case let value as Data:
        return value.base64EncodedString()
    case let value as Buffer:
        return value.makeData().base64EncodedString()
    case let value as [Any?]:
        return value.map { pluginJSONValue($0, depth: depth + 1) }
    case let value as [Any]:
        return value.map { pluginJSONValue($0, depth: depth + 1) }
    default:
        if let description = value as? TypeConstructorDescription {
            let (name, parameters) = description.descriptionFields()
            if name == "boolTrue" || name == "true" {
                return true
            }
            if name == "boolFalse" || name == "false" {
                return false
            }
            // A nested TL value becomes an object of its fields instead of the
            // constructor name, so `updateNewMessage` carries a `message` with
            // `peer_id`, `id` and `message` in it. From here the plugin can do
            // what the Android module did: remember a message before it is
            // deleted, and filter by sender. The old string form made every one
            // of those features impossible, not merely awkward.
            //
            // `depth` bounds the walk: a TL tree is finite, but `message` nests
            // `media`, which nests `document`, and a runaway description must
            // never stall the request path.
            if depth >= 8 {
                return name
            }
            var result: [String: Any] = ["_": name]
            for (fieldName, fieldValue) in parameters {
                result[fieldName] = pluginJSONValue(fieldValue.value, depth: depth + 1)
            }
            return result
        }
        if let value = value {
            return String(describing: value)
        }
        return NSNull()
    }
}

/// Any TL value as a JSON object of its fields.
///
/// A generated `Api.*` value describes itself by constructor name plus fields
/// (`TypeConstructorDescription`), which is the shape a plugin's
/// `post_request_hook` gets on Android. Anything that cannot describe itself
/// keeps the constructor-name fallback from `pluginJSONValue`.
func pluginValueJSON(_ value: Any?) -> String {
    // Delegates to `pluginJSONValue` so a response and a request parameter are
    // described the same way: `Api.Bool` answers a real boolean, nested objects
    // answer their fields, and primitives pass through.
    if let object = pluginJSONValue(value) as? [String: Any] {
        return pluginJSONString(object)
    }
    return pluginJSONString(["_": pluginJSONValue(value)])
}

/// One update as a plugin's `on_update_hook` sees it.
///
/// The constructor name is the identifier exteraGram matches against
/// (`updateNewMessage`), and the fields are flattened exactly like a request's
/// parameters. `descriptionFields()` reads the schema table, so it cannot fail;
/// an update with no fields simply arrives as an empty dictionary.
func pluginUpdateFields(_ update: Api.Update) -> (name: String, fields: [String: Any]) {
    // `Api.Update` conforms to `TypeConstructorDescription`, so this is a plain
    // call rather than a conditional cast; the generated enums describe
    // themselves from the schema table.
    let (name, parameters) = update.descriptionFields()
    var fields: [String: Any] = [:]
    for (fieldName, value) in parameters {
        fields[fieldName] = pluginJSONValue(value.value)
    }
    return (name, fields)
}

/// `JSONSerialization` output as text, `"{}"` when the object cannot be encoded.
///
/// Every value reaching this point already came from `pluginJSONValue`, so a
/// failure means a non-JSON type slipped through; degrading to an empty object
/// keeps a hook from throwing into the account state machine.
func pluginJSONString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}
