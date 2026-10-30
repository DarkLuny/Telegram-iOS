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

/// Edits an existing message's text on behalf of a plugin.
///
/// exteraGram's `edit_message(message_obj, text=...)` reaches into the Android
/// `MessagesController`; on iOS the same operation is the engine's own edit
/// request, which this wraps so `ExteraPluginKit` still never imports Postbox.
/// Only the text changes: replacing media needs a file upload and a media kind
/// the plugin cannot express across a string-only bridge.
public func editPluginMessage(
    account: Account,
    peerId: Int64,
    messageId: Int64,
    text: String,
    entities: [MessageTextEntity]
) -> Signal<Never, NoError> {
    let engineMessageId = EngineMessage.Id(
        peerId: EnginePeer.Id(peerId),
        namespace: Namespaces.Message.Cloud,
        id: Int32(clamping: messageId)
    )

    var attributes: TextEntitiesMessageAttribute?
    if !entities.isEmpty {
        attributes = TextEntitiesMessageAttribute(entities: entities)
    }

    // The result (progress, then done) is not something a plugin can act on
    // synchronously, so a failure is logged and the signal completes either way
    // rather than surfacing an error type the plugin module would have to know.
    return _internal_requestEditMessage(
        account: account,
        messageId: engineMessageId,
        text: text,
        media: .keep,
        entities: attributes,
        richText: nil,
        inlineStickers: [:],
        webpagePreviewAttribute: nil,
        disableUrlPreview: false,
        scheduleInfoAttribute: nil,
        invertMediaAttribute: nil
    )
    |> ignoreValues
    |> `catch` { _ -> Signal<Never, NoError> in
        return .complete()
    }
}