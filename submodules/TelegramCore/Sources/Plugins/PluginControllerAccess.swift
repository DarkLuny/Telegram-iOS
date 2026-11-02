import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import LocalizedPeerData

/// Reads for the plugin runtime's controller proxies.
///
/// exteraGram's `client_utils.get_messages_controller()` and its siblings hand a
/// plugin the Android client's own singleton objects, which is how a plugin reads
/// a chat's messages, a peer's profile or the account's config. There is no such
/// object here, and handing one out would mean exposing the engine to scripts.
///
/// What this provides instead is the data those controllers are used for, in the
/// shape a plugin can consume: plain JSON, resolved off the account's queues
/// through `Signal` so nothing blocks. A plugin ported from Android calls our
/// method names instead of Android's — that is a rewrite of the call site, not a
/// drop-in, and it is the honest version of "the controller returns something".
///
/// Lives in TelegramCore for the same reason `PluginProxyAccess` does:
/// `ExteraPluginKit` must not import Postbox or the engine.
public enum PluginControllerAccess {
    /// A peer's profile, flattened to data rather than an `EnginePeer`.
    ///
    /// The id is the numeric peer id a plugin already uses for `send_*`. Titles,
    /// usernames and flags are copied out; nothing references the live peer
    /// object after the signal completes.
    public struct PeerInfo {
        public let id: Int64
        public let kind: String
        public let title: String
        public let username: String?
        public let firstName: String?
        public let lastName: String?
        public let isVerified: Bool
        public let isScam: Bool
        public let isFake: Bool
        public let isBot: Bool
        public let isPremium: Bool
        public let isDeleted: Bool

        public var json: [String: Any] {
            var object: [String: Any] = [
                "id": self.id,
                "kind": self.kind,
                "title": self.title,
                "verified": self.isVerified,
                "scam": self.isScam,
                "fake": self.isFake,
                "bot": self.isBot,
                "premium": self.isPremium,
                "deleted": self.isDeleted,
            ]
            if let username = self.username { object["username"] = username }
            if let firstName = self.firstName { object["first_name"] = firstName }
            if let lastName = self.lastName { object["last_name"] = lastName }
            return object
        }
    }

    /// One message, flattened to the fields a plugin's loop actually reads.
    ///
    /// The full engine message is deliberately not passed through: it is a deep,
    /// reference-heavy value, and a plugin wanting more than this has
    /// `extended_message_details`'s own hook payload to reach for.
    public struct MessageSummary {
        public let id: Int32
        public let peerId: Int64
        public let authorId: Int64?
        public let timestamp: Int32
        public let text: String
        public let isOutgoing: Bool
        public let hasMedia: Bool
        public let mediaKind: String?
        public let replyToMessageId: Int32?
        public let editTimestamp: Int32?
        public let isAction: Bool

        public var json: [String: Any] {
            var object: [String: Any] = [
                "id": self.id,
                "peer_id": self.peerId,
                "date": self.timestamp,
                "text": self.text,
                "out": self.isOutgoing,
                "has_media": self.hasMedia,
                "action": self.isAction,
            ]
            if let authorId = self.authorId { object["author_id"] = authorId }
            if let mediaKind = self.mediaKind { object["media_kind"] = mediaKind }
            if let replyToMessageId = self.replyToMessageId { object["reply_to_msg_id"] = Int(replyToMessageId) }
            if let editTimestamp = self.editTimestamp { object["edit_date"] = editTimestamp }
            return object
        }
    }

    /// The peer behind a numeric id, or nil when nothing is cached for it.
    public static func peerInfo(context: AccountContext, peerId: Int64) -> Signal<PeerInfo?, NoError> {
        let peer = PluginControllerAccess.peerId(from: peerId)
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peer))
        |> map { enginePeer -> PeerInfo? in
            guard let enginePeer = enginePeer else {
                return nil
            }
            return PluginControllerAccess.summarize(enginePeer, peerId: peerId, strings: strings)
        }
    }

    /// The most recent messages of one chat, newest first, capped at `limit`.
    ///
    /// Read from the message history view rather than the postbox directly, so
    /// the result matches what the chat screen shows, including a chat whose
    /// history is not fully loaded yet. `limit` is clamped: a plugin asking for a
    /// thousand messages gets a page the UI itself would never build.
    public static func chatMessages(context: AccountContext, peerId: Int64, limit: Int) -> Signal<[MessageSummary], NoError> {
        let count = max(1, min(limit, 200))
        let peer = PluginControllerAccess.peerId(from: peerId)
        let key: PostboxViewKey = .historyView(PostboxViewKey.HistoryView(
            peerId: peer,
            namespace: Namespaces.Message.Cloud,
            tag: .all,
            threadId: nil,
            minId: nil,
            maxId: nil,
            earlier: false,
            count: count,
            clipView: false
        ))
        return context.account.postbox.combinedView(keys: [key])
        |> take(1)
        |> map { views -> [MessageSummary] in
            guard let view = views.views[key] as? MessageHistoryView else {
                return []
            }
            return view.entries.compactMap { entry in
                return PluginControllerAccess.summarize(entry.message)
            }
        }
    }

    // MARK: - Conversion

    private static func summarize(_ enginePeer: EnginePeer, peerId: Int64, strings: PresentationStrings) -> PeerInfo {
        var firstName: String?
        var lastName: String?
        var isBot = false
        if case let .user(user) = enginePeer, user.botInfo != nil {
            isBot = true
        }
        if case let .personName(first, last, _, _) = enginePeer.indexName {
            firstName = first
            lastName = last
        }
        return PeerInfo(
            id: peerId,
            kind: PluginControllerAccess.kind(of: enginePeer),
            title: enginePeer.displayTitle(strings: strings, displayOrder: strings.nameDisplayOrder),
            username: enginePeer.addressName,
            firstName: firstName,
            lastName: lastName,
            isVerified: enginePeer.isVerified,
            isScam: enginePeer.isScam,
            isFake: enginePeer.isFake,
            isBot: isBot,
            isPremium: enginePeer.isPremium,
            isDeleted: enginePeer.isDeleted
        )
    }

    private static func summarize(_ message: Message) -> MessageSummary {
        var hasMedia = false
        var mediaKind: String?
        var isAction = false
        for media in message.media {
            switch media {
            case let .image(_, _, _):
                hasMedia = true
                mediaKind = "photo"
            case let .file(file):
                hasMedia = true
                if file.isVideo {
                    mediaKind = "video"
                } else if file.isVoice {
                    mediaKind = "voice"
                } else if file.isMusic {
                    mediaKind = "audio"
                } else {
                    mediaKind = "document"
                }
            case .webPage:
                hasMedia = true
                mediaKind = "webpage"
            case .poll:
                hasMedia = true
                mediaKind = "poll"
            case is TelegramMediaAction:
                isAction = true
            default:
                hasMedia = true
            }
        }
        var replyTo: Int32?
        var editDate: Int32?
        for attribute in message.attributes {
            if let reply = attribute as? ReplyMessageAttribute {
                replyTo = reply.messageId.id
            }
            if let edited = attribute as? EditedMessageAttribute {
                editDate = edited.date
            }
        }
        return MessageSummary(
            id: message.id.id,
            peerId: PluginControllerAccess.numericId(of: message.id.peerId),
            authorId: message.author.flatMap { PluginControllerAccess.numericId(of: $0.id) },
            timestamp: message.timestamp,
            text: message.text,
            // `MessageFlags` has no `Outgoing` member; a message is incoming
            // unless its `.Incoming` bit is set.
            isOutgoing: !message.flags.contains(.Incoming),
            hasMedia: hasMedia,
            mediaKind: mediaKind,
            replyToMessageId: replyTo,
            editTimestamp: editDate,
            isAction: isAction
        )
    }

    /// The lowercase kind a plugin branches on.
    private static func kind(of enginePeer: EnginePeer) -> String {
        switch enginePeer {
        case .user:
            return "user"
        case .legacyGroup:
            return "group"
        case .channel:
            return "channel"
        case .community:
            return "community"
        case .secretChat:
            return "secret"
        }
    }

    /// The `PeerId` a plugin's numeric id names.
    ///
    /// The client's own coding puts users in the `peer` namespace with a positive
    /// id, basic groups with a small negative one, and channels below
    /// `-1000000000000`. Rebuilding the namespace from the sign is what makes a
    /// value that came out of one hook usable in another.
    static func peerId(from value: Int64) -> PeerId {
        if value > 0 {
            return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(value))
        } else if value > -1000000000000 {
            return PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(value))
        } else {
            // `-100xxxxxxxxxx` carries the channel id after the marker; the
            // namespace stores the bare negative id.
            let channel = value + 1000000000000
            return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(channel))
        }
    }

    /// The signed numeric id a plugin sees for a peer.
    static func numericId(of peerId: PeerId) -> Int64 {
        let raw = peerId.id._internalGetInt64Value()
        switch peerId.namespace {
        case Namespaces.Peer.CloudUser:
            return raw
        case Namespaces.Peer.CloudGroup:
            return raw
        case Namespaces.Peer.CloudChannel:
            return -1000000000000 + raw
        default:
            return raw
        }
    }
}
