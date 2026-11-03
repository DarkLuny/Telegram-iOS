import Foundation
import Postbox
import SwiftSignalKit

func _internal_setSecretChatMessageAutoremoveTimeoutInteractively(account: Account, peerId: PeerId, timeout: Int32?) -> Signal<Void, NoError> {
    return account.postbox.transaction { transaction -> Void in
        _internal_setSecretChatMessageAutoremoveTimeoutInteractively(transaction: transaction, account: account, peerId: peerId, timeout: timeout)
    }
}

func _internal_setSecretChatMessageAutoremoveTimeoutInteractively(transaction: Transaction, account: Account, peerId: PeerId, timeout: Int32?) {
    if let peer = transaction.getPeer(peerId) as? TelegramSecretChat, let state = transaction.getPeerChatState(peerId) as? SecretChatState {
        if state.messageAutoremoveTimeout != timeout {
            let updatedPeer = peer.withUpdatedMessageAutoremoveTimeout(timeout)
            let updatedState = state.withUpdatedMessageAutoremoveTimeout(timeout)
            if !updatedPeer.isEqual(peer) {
                updatePeersCustom(transaction: transaction, peers: [updatedPeer], update: { $1 })
            }
            if updatedState != state {
                transaction.setPeerChatState(peerId, state: updatedState)
            }
            
            let _ = enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: [(true, .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaAction(action: TelegramMediaActionType.messageAutoremoveTimeoutUpdated(period: timeout == nil ? 0 : timeout!, autoSettingSource: nil))), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))])
        }
    }
}

func _internal_addSecretChatMessageScreenshot(account: Account, peerId: PeerId) -> Signal<Void, NoError> {
    // The report is a message, not a protection flag: a plugin that lets the user
    // capture a secret chat has to silence this too, or the peer learns about a
    // screenshot of content the plugin said was free to capture. The hook is read
    // before the transaction so a quiet client pays one optional check.
    if PluginHookPoints.shared.suppressScreenshotReport?() == true {
        return .complete()
    }
    return account.postbox.transaction { transaction -> Void in
        if let _ = transaction.getPeer(peerId) as? TelegramSecretChat, let state = transaction.getPeerChatState(peerId) as? SecretChatState {
            switch state.embeddedState {
            case .handshake, .terminated:
                return
            default:
                break
            }
            let _ = enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: [(true, .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaAction(action: TelegramMediaActionType.historyScreenshot)), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))])
        }
    }
}
