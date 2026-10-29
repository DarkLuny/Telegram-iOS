import Foundation
import SwiftSignalKit
import Postbox

/// What a plugin asked to send, in terms a consumer can build without Postbox.
///
/// Everything a plugin can attach: text with entities, a local file, the reply
/// it answers, and the two flags exteraGram exposes (silent posting, a caption).
public enum EngineOutgoingPluginMessage {
    /// Text with entities already resolved, as `sendText` produces them.
    case text(String, [MessageTextEntity])

    /// A local file that still has to be uploaded.
    ///
    /// `photoDimensions` is non-nil when the file should arrive as a picture
    /// bubble; the caller decodes the image and supplies its pixel size, because
    /// only it has a `UIImage` at hand. Everything else is sent as a document.
    case localFile(
        path: String,
        mimeType: String,
        fileName: String,
        size: Int64?,
        photoDimensions: PixelDimensions?,
        caption: String,
        captionEntities: [MessageTextEntity]
    )
}

/// Sends one message a plugin asked for.
///
/// This exists so `ExteraPluginKit` never has to `import Postbox`: turning a
/// path into a `LocalFileReferenceMediaResource` and a `TelegramMediaImage` or
/// `TelegramMediaFile` belongs to the engine, which already owns those types.
/// The plugin module only describes what it wants sent.
public func enqueuePluginMessage(
    account: Account,
    peerId: Int64,
    replyToMessageId: Int64?,
    silentPosting: Bool,
    content: EngineOutgoingPluginMessage
) -> Signal<Never, NoError> {
    // Plugins speak in raw `Int64` ids, because a plugin has no Postbox types;
    // `PeerId` is one, so the conversion stays here.
    let enginePeerId = EnginePeer.Id(peerId)

    var attributes: [MessageAttribute] = []
    if silentPosting {
        attributes.append(NotificationInfoMessageAttribute(flags: .muted))
    }

    // A plugin names the message it answers by id alone; the peer is the one the
    // new message goes to, and only cloud messages can be replied to.
    let replyTo: EngineMessageReplySubject?
    if let replyToMessageId = replyToMessageId {
        replyTo = EngineMessageReplySubject(
            messageId: EngineMessage.Id(
                peerId: enginePeerId,
                namespace: Namespaces.Message.Cloud,
                id: Int32(clamping: replyToMessageId)
            ),
            quote: nil,
            innerSubject: nil
        )
    } else {
        replyTo = nil
    }

    var text = ""
    var mediaReference: AnyMediaReference?

    switch content {
    case let .text(value, entities):
        if !entities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
        }
        text = value

    case let .localFile(path, mimeType, fileName, size, photoDimensions, caption, captionEntities):
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileReferenceMediaResource(
            localFilePath: path,
            randomId: randomId,
            isUniquelyReferencedTemporaryFile: false,
            size: size
        )

        if let photoDimensions = photoDimensions {
            let image = TelegramMediaImage(
                imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: randomId),
                representations: [TelegramMediaImageRepresentation(
                    dimensions: photoDimensions,
                    resource: resource,
                    progressiveSizes: [],
                    immediateThumbnailData: nil
                )],
                immediateThumbnailData: nil,
                reference: nil,
                partialReference: nil,
                flags: []
            )
            mediaReference = AnyMediaReference.standalone(media: image)
        } else {
            let file = TelegramMediaFile(
                fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId),
                partialReference: nil,
                resource: resource,
                previewRepresentations: [],
                videoThumbnails: [],
                immediateThumbnailData: nil,
                mimeType: mimeType,
                size: size,
                attributes: [.FileName(fileName: fileName)],
                alternativeRepresentations: []
            )
            mediaReference = AnyMediaReference.standalone(media: file)
        }

        if !captionEntities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: captionEntities))
        }
        text = caption
    }

    let message = EnqueueMessage.message(
        text: text,
        attributes: attributes,
        inlineStickers: [:],
        mediaReference: mediaReference,
        threadId: nil,
        replyToMessageId: replyTo,
        replyToStoryId: nil,
        localGroupingKey: nil,
        correlationId: nil,
        bubbleUpEmojiOrStickersets: []
    )
    return enqueueMessages(account: account, peerId: enginePeerId, messages: [message])
    |> ignoreValues
}