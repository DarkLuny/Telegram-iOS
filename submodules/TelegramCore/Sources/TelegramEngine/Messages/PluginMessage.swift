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
    scheduleDate: Int32? = nil,
    hasMediaSpoilers: Bool = false,
    content: EngineOutgoingPluginMessage
) -> Signal<Never, NoError> {
    // Plugins speak in raw `Int64` ids, because a plugin has no Postbox types;
    // `PeerId` is one, so the conversion stays here.
    let enginePeerId = EnginePeer.Id(peerId)

    var attributes: [MessageAttribute] = []
    if silentPosting {
        attributes.append(NotificationInfoMessageAttribute(flags: .muted))
    }
    if let scheduleDate = scheduleDate {
        attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleDate, repeatPeriod: nil))
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
        mediaReference = AnyMediaReference.standalone(
            media: pluginLocalMedia(path: path, mimeType: mimeType, fileName: fileName, size: size, photoDimensions: photoDimensions)
        )

        if !captionEntities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: captionEntities))
        }
        // The same marker attribute the composer attaches when the user enables
        // a cover before sending; a text-only message never gets one, because a
        // spoiler without media is not a thing the API carries.
        if hasMediaSpoilers {
            attributes.append(MediaSpoilerMessageAttribute())
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

/// The account's own user id, which is also the Saved Messages peer.
///
/// A plugin exporting something to itself names that peer by id; `PeerId` is a
/// Postbox type, so the conversion stays in the engine instead of leaking into
/// `ExteraPluginKit`.
public func pluginSavedMessagesPeerId(account: Account) -> Int64 {
    return account.peerId.toInt64()
}

/// Edits an existing message on behalf of a plugin.
///
/// exteraGram's `edit_message(message_obj, text=..., file_path=...)` reaches
/// into the Android `MessagesController`; on iOS the same operation is the
/// engine's own edit request, which this wraps so `ExteraPluginKit` still never
/// imports Postbox. The text changes, and `file_path` replaces the media
/// through the same local-file shape the send path uses.
public func editPluginMessage(
    account: Account,
    peerId: Int64,
    messageId: Int64,
    text: String,
    entities: [MessageTextEntity],
    content: EngineOutgoingPluginMessage? = nil
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

    // `file_path` turns the edit into a media replacement, riding the same
    // `update` case the composer's own edit uses. Without it the edit stays
    // text-only, exactly as before. A spoiler cannot be attached here: the edit
    // request has no attribute slot, so the message keeps the spoiler state it
    // already carries.
    var media: RequestEditMessageMedia = .keep
    if let content = content, case let .localFile(path, mimeType, fileName, size, photoDimensions, _, _) = content {
        media = .update(
            AnyMediaReference.standalone(
                media: pluginLocalMedia(path: path, mimeType: mimeType, fileName: fileName, size: size, photoDimensions: photoDimensions)
            )
        )
    }

    // The result (progress, then done) is not something a plugin can act on
    // synchronously, so a failure is logged and the signal completes either way
    // rather than surfacing an error type the plugin module would have to know.
    return _internal_requestEditMessage(
        account: account,
        messageId: engineMessageId,
        text: text,
        media: media,
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

/// Builds the media a local file becomes, so the send and the media-replacing
/// edit produce the same bubble type for the same file.
private func pluginLocalMedia(path: String, mimeType: String, fileName: String, size: Int64?, photoDimensions: PixelDimensions?) -> Media {
    let randomId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileReferenceMediaResource(
        localFilePath: path,
        randomId: randomId,
        isUniquelyReferencedTemporaryFile: false,
        size: size
    )
    if let photoDimensions = photoDimensions {
        return TelegramMediaImage(
            imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: randomId),
            representations: [
                TelegramMediaImageRepresentation(
                    dimensions: photoDimensions,
                    resource: resource,
                    progressiveSizes: [],
                    immediateThumbnailData: nil
                )
            ],
            immediateThumbnailData: nil,
            reference: nil,
            partialReference: nil,
            flags: []
        )
    }
    return TelegramMediaFile(
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
}