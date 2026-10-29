import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

class UpdateMessageService: NSObject, NetworkEngineUpdateSink {
    var peerId: PeerId!
    let pipe: ValuePipe<[UpdateGroup]> = ValuePipe()
    
    override init() {
        super.init()
    }
    
    convenience init(peerId: PeerId) {
        self.init()
        self.peerId = peerId
    }
    
    func networkSessionDidReset() {
        self.pipe.putNext([.reset])
    }
    
    func putNext(_ groups: [UpdateGroup]) {
        self.pipe.putNext(groups)
    }
    
    func networkSessionDidReceive(message: Any) {
        if let updates = (message as? BoxedMessage)?.body as? Api.Updates {
            self.addUpdates(updates)
        }
    }
    
    /// Publishes a group batch and, when a plugin subscribed, reports the raw
    /// updates it contains. One place, so every branch of `addUpdates` stays
    /// hooked without repeating the check.
    private func deliver(_ groups: [UpdateGroup]) {
        self.pipe.putNext(groups)

        let hookPoints = PluginHookPoints.shared
        let receivedUpdate = hookPoints.receivedUpdate
        let receivedUpdates = hookPoints.receivedUpdates
        guard receivedUpdate != nil || receivedUpdates != nil else {
            return
        }
        let updates = groups.flatMap { $0.updates }
        guard !updates.isEmpty else {
            return
        }
        let accountId = self.peerId.toInt64()
        let wants = hookPoints.wantsUpdate

        // Described once, then reused for the per-update and the batch hook:
        // `descriptionFields()` walks every field and is the only expensive part
        // of this path.
        var describedUpdates: [(name: String, fields: [String: Any])] = []
        for update in updates {
            guard let described = pluginUpdateFields(update) else {
                continue
            }
            describedUpdates.append(described)
        }

        if let receivedUpdate = receivedUpdate {
            for described in describedUpdates {
                if let wants = wants, !wants(described.name) {
                    continue
                }
                receivedUpdate(accountId, described.name, pluginJSONString(described.fields))
            }
        }
        // A batch is worth building only for a plugin that registered `updates`
        // or `*`; describing every update on the off-chance would cost more than
        // the whole state application does.
        if let receivedUpdates = receivedUpdates, wants?("updates") ?? true {
            let items = describedUpdates.map { ["name": $0.name, "fields": $0.fields] as [String: Any] }
            receivedUpdates(accountId, pluginJSONString(["updates": items]))
        }
    }

    func addUpdates(_ updates: Api.Updates) {
        switch updates {
            case let .updates(updatesData):
                let (updates, users, chats, date, seq) = (updatesData.updates, updatesData.users, updatesData.chats, updatesData.date, updatesData.seq)
                let groups = groupUpdates(updates, users: users, chats: chats, date: date, seqRange: seq == 0 ? nil : (seq, 1))
                if groups.count != 0 {
                    self.deliver(groups)
                }
            case let .updatesCombined(updatesCombinedData):
                let (updates, users, chats, date, seqStart, seq) = (updatesCombinedData.updates, updatesCombinedData.users, updatesCombinedData.chats, updatesCombinedData.date, updatesCombinedData.seqStart, updatesCombinedData.seq)
                let groups = groupUpdates(updates, users: users, chats: chats, date: date, seqRange: seq == 0 ? nil : (seq, seq - seqStart))
                if groups.count != 0 {
                    self.deliver(groups)
                }
            case let .updateShort(updateShortData):
                let (update, date) = (updateShortData.update, updateShortData.date)
                let groups = groupUpdates([update], users: [], chats: [], date: date, seqRange: nil)
                if groups.count != 0 {
                    self.deliver(groups)
                }
            case let .updateShortChatMessage(updateShortChatMessageData):
                let (flags, id, fromId, chatId, message, pts, ptsCount, date, fwdFrom, viaBotId, replyHeader, entities, ttlPeriod) = (updateShortChatMessageData.flags, updateShortChatMessageData.id, updateShortChatMessageData.fromId, updateShortChatMessageData.chatId, updateShortChatMessageData.message, updateShortChatMessageData.pts, updateShortChatMessageData.ptsCount, updateShortChatMessageData.date, updateShortChatMessageData.fwdFrom, updateShortChatMessageData.viaBotId, updateShortChatMessageData.replyTo, updateShortChatMessageData.entities, updateShortChatMessageData.ttlPeriod)
                    let generatedMessage = Api.Message.message(.init(flags: flags, flags2: 0, id: id, fromId: .peerUser(.init(userId: fromId)), fromBoostsApplied: nil, fromRank: nil, peerId: Api.Peer.peerChat(.init(chatId: chatId)), savedPeerId: nil, fwdFrom: fwdFrom, viaBotId: viaBotId, viaBusinessBotId: nil, guestchatViaFrom: nil, replyTo: replyHeader, date: date, message: message, media: Api.MessageMedia.messageMediaEmpty, replyMarkup: nil, entities: entities, views: nil, forwards: nil, replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: ttlPeriod, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil, suggestedPost: nil, scheduleRepeatPeriod: nil, summaryFromLanguage: nil, richMessage: nil))
                let update = Api.Update.updateNewMessage(.init(message: generatedMessage, pts: pts, ptsCount: ptsCount))
                let groups = groupUpdates([update], users: [], chats: [], date: date, seqRange: nil)
                if groups.count != 0 {
                    self.deliver(groups)
                }
            case let .updateShortMessage(updateShortMessageData):
                let (flags, id, userId, message, pts, ptsCount, date, fwdFrom, viaBotId, replyHeader, entities, ttlPeriod) = (updateShortMessageData.flags, updateShortMessageData.id, updateShortMessageData.userId, updateShortMessageData.message, updateShortMessageData.pts, updateShortMessageData.ptsCount, updateShortMessageData.date, updateShortMessageData.fwdFrom, updateShortMessageData.viaBotId, updateShortMessageData.replyTo, updateShortMessageData.entities, updateShortMessageData.ttlPeriod)
                let generatedFromId: Api.Peer
                if (Int(flags) & 1 << 1) != 0 {
                    generatedFromId = Api.Peer.peerUser(.init(userId: self.peerId.id._internalGetInt64Value()))
                } else {
                    generatedFromId = Api.Peer.peerUser(.init(userId: userId))
                }

                let generatedPeerId = Api.Peer.peerUser(.init(userId: userId))

                let generatedMessage = Api.Message.message(.init(flags: flags, flags2: 0, id: id, fromId: generatedFromId, fromBoostsApplied: nil, fromRank: nil, peerId: generatedPeerId, savedPeerId: nil, fwdFrom: fwdFrom, viaBotId: viaBotId, viaBusinessBotId: nil, guestchatViaFrom: nil, replyTo: replyHeader, date: date, message: message, media: Api.MessageMedia.messageMediaEmpty, replyMarkup: nil, entities: entities, views: nil, forwards: nil, replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: ttlPeriod, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil, suggestedPost: nil, scheduleRepeatPeriod: nil, summaryFromLanguage: nil, richMessage: nil))
                let update = Api.Update.updateNewMessage(.init(message: generatedMessage, pts: pts, ptsCount: ptsCount))
                let groups = groupUpdates([update], users: [], chats: [], date: date, seqRange: nil)
                if groups.count != 0 {
                    self.deliver(groups)
                }
            case .updatesTooLong:
                self.pipe.putNext([.reset])
            case let .updateShortSentMessage(updateShortSentMessageData):
                let (pts, ptsCount) = (updateShortSentMessageData.pts, updateShortSentMessageData.ptsCount)
                self.pipe.putNext([.updatePts(pts: pts, ptsCount: ptsCount)])
        }
    }
}
