import Foundation
import UIKit
import Postbox
import TelegramCore
import TemporaryCachedPeerDataManager
import Emoji
import AccountContext
import TelegramPresentationData
import ChatHistoryEntry
import ChatMessageItemCommon
import TextFormat
import Markdown
import Display
import TelegramStringFormatting

struct ChatHistoryEntriesForViewState {
    private var messageStableIdToLocalId: [UInt32: Int64] = [:]
    
    init() {
    }
    
    mutating func messageGroupStableId(messageStableId: UInt32, groupId: Int64, isLocal: Bool) -> Int64 {
        if isLocal {
            self.messageStableIdToLocalId[messageStableId] = groupId
            return groupId
        } else {
            if let value = self.messageStableIdToLocalId[messageStableId] {
                return value
            } else {
                return groupId
            }
        }
    }
}

func chatHistoryEntriesForView(
    currentState: ChatHistoryEntriesForViewState,
    context: AccountContext,
    location: ChatLocation,
    subject: ChatControllerSubject?,
    view: MessageHistoryView,
    includeUnreadEntry: Bool,
    includeEmptyEntry: Bool,
    includeChatInfoEntry: Bool,
    includeEmbeddedSavedChatInfo: Bool,
    reverse: Bool,
    groupMessages: Bool,
    reverseGroupedMessages: Bool,
    selectedMessages: Set<MessageId>?,
    presentationData: ChatPresentationData,
    historyAppearsCleared: Bool,
    skipViewOnceMedia: Bool,
    pendingUnpinnedAllMessages: Bool,
    pendingRemovedMessages: Set<MessageId>,
    associatedData: ChatMessageItemAssociatedData,
    updatingMedia: [MessageId: ChatUpdatingMessageMedia],
    customChannelDiscussionReadState: MessageId?,
    customThreadOutgoingReadState: MessageId?,
    cachedData: CachedPeerData?,
    adMessage: Message?,
    dynamicAdMessages: [Message],
    isMusicPlaylist: Bool,
    pinToTopStableId: EngineMessage.StableId?
) -> ([ChatHistoryEntry], ChatHistoryEntriesForViewState) {
    var currentState = currentState
    
    if historyAppearsCleared {
        return ([], currentState)
    }
    var entries: [ChatHistoryEntry] = []
    var adminRanks: [PeerId: CachedChannelAdminRank] = [:]
    var stickersEnabled = true
    var chatPeer: Peer?
    var cachedPeerDataPeers: [PeerId: Peer] = [:]
    if let peerId = location.peerId {
        for additionalEntry in view.additionalData {
            if case let .cacheEntry(id, data) = additionalEntry {
                if peerId.namespace == Namespaces.Peer.CloudChannel {
                    if id == cachedChannelAdminRanksEntryId(peerId: peerId), let data = data?.get(CachedChannelAdminRanks.self) {
                        adminRanks = data.ranks
                    }
                }
            } else if case let .peer(_, peer) = additionalEntry {
                chatPeer = peer
                if let channel = peer as? TelegramChannel, !channel.flags.contains(.isGigagroup) {
                    if let defaultBannedRights = channel.defaultBannedRights, defaultBannedRights.flags.contains(.banSendStickers) {
                        stickersEnabled = false
                    }
                }
            } else if case let .cachedPeerData(_, peerData) = additionalEntry {
                if let cachedGroupData = peerData as? CachedGroupData, let participants = cachedGroupData.participants {
                    for participant in participants.participants {
                        switch participant {
                        case let .member(_, _, _, rank):
                            adminRanks[participant.peerId] = .member(rank)
                        case let .creator(_, rank):
                            adminRanks[participant.peerId] = .creator(rank)
                        case let .admin(_, _, _, rank):
                            adminRanks[participant.peerId] = .admin(rank)
                        }
                    }
                }
            } else if case let .cachedPeerDataPeers(_, peers) = additionalEntry {
                cachedPeerDataPeers = peers
            }
        }
    }
    
    var joinMessage: Message?
    if (associatedData.subject?.isService ?? false) {
        
    } else {
        if let peer = chatPeer as? TelegramChannel, case .broadcast = peer.info, case .member = peer.participationStatus, !peer.flags.contains(.isCreator) {
            joinMessage = Message(
                stableId: UInt32.max - 1000,
                stableVersion: 0,
                id: MessageId(peerId: peer.id, namespace: Namespaces.Message.Local, id: 0),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: peer.creationDate,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: chatPeer,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .joinedChannel)],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
        }
    }
    
    // Asked once, before the loop. `hideMessage` takes an already encoded
    // message, and encoding every visible row only to be told that no plugin
    // listens would put a JSON document per row on the list's build path. With
    // no listener both closures are `nil`/`false` and this file behaves exactly
    // as stock.
    let pluginsMayHideMessages = PluginHookPoints.shared.wantsHideMessage?() == true

    var count = 0
    loop: for entry in view.entries {
        var message = entry.message.withAppliedEphemeralReplacementMessage()
        var isRead = entry.isRead
        
        var pinToTop = false
        if message.stableId == pinToTopStableId {
            pinToTop = true
        }
        
        if pendingRemovedMessages.contains(message.id) {
            continue
        }
        
        if case let .replyThread(replyThreadMessage) = location, replyThreadMessage.isForumPost {
            for media in message.media {
                if let action = media as? TelegramMediaAction {
                    if case .topicCreated = action.action {
                        continue loop
                    } else if case .groupCreated = action.action {
                        var chatPeer: Peer?
                        for entry in view.additionalData {
                            if case let .peer(_, peer) = entry {
                                chatPeer = peer
                            }
                        }
                        if let channel = chatPeer as? TelegramChannel, channel.isMonoForum {
                            continue loop
                        } else if let user = chatPeer as? TelegramUser, user.isForum {
                            continue loop
                        }
                    }
                }
            }
        } else if case .peer = location {
            for media in message.media {
                if let action = media as? TelegramMediaAction, case .groupCreated = action.action {
                    var chatPeer: Peer?
                    for entry in view.additionalData {
                        if case let .peer(_, peer) = entry {
                            chatPeer = peer
                        }
                    }
                    if let channel = chatPeer as? TelegramChannel, channel.isMonoForum {
                        continue loop
                    } else if let user = chatPeer as? TelegramChannel, user.isForum {
                        continue loop
                    }
                }
            }
        }
        
        count += 1
        
        if let customThreadOutgoingReadState = customThreadOutgoingReadState {
            isRead = customThreadOutgoingReadState >= message.id
        }
        
        if let customChannelDiscussionReadState = customChannelDiscussionReadState {
            attibuteLoop: for i in 0 ..< message.attributes.count {
                if let attribute = message.attributes[i] as? ReplyThreadMessageAttribute {
                    if let maxReadMessageId = attribute.maxReadMessageId {
                        if maxReadMessageId < customChannelDiscussionReadState.id {
                            var attributes = message.attributes
                            attributes[i] = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: customChannelDiscussionReadState.id)
                            message = message.withUpdatedAttributes(attributes)
                        }
                    }
                    break attibuteLoop
                }
            }
        }
        
        if skipViewOnceMedia, let minAutoremoveOrClearTimeout = message.minAutoremoveOrClearTimeout {
            if minAutoremoveOrClearTimeout <= 60 {
                continue loop
            }
        }

        // A plugin can hide a row: that is how the re:extera module's shadow ban
        // and its regex filters reach this client. The check runs after the
        // built-in skips and before anything is built for the row, so a hidden
        // message costs one JSON encode and no entry. `hideMessage` is `nil`
        // when no plugin listens, which is the common case.
        if pluginsMayHideMessages,
           let hideMessage = PluginHookPoints.shared.hideMessage,
           hideMessage(context.account.id.int64, pluginMessageDetailsJSON(message)) {
            continue loop
        }
        
        var contentTypeHint: ChatMessageEntryContentType = .generic
        
        for media in message.media {
            if media is TelegramMediaDice {
                contentTypeHint = .animatedEmoji
            }
            if let action = media as? TelegramMediaAction {
                switch action.action {
                    case .channelMigratedFromGroup, .groupMigratedToChannel, .historyCleared:
                        continue loop
                    default:
                        break
                }
            }
        }
    
        var adminRank: CachedChannelAdminRank?
        if let author = message.author {
            adminRank = adminRanks[author.id]
        }
        
        if presentationData.largeEmoji, message.media.isEmpty {
            if messageIsEligibleForLargeCustomEmoji(EngineMessage(message)) {
                contentTypeHint = .animatedEmoji
            } else if stickersEnabled && message.text.count == 1, let _ = associatedData.animatedEmojiStickers[message.text.basicEmoji.0], (message.textEntitiesAttribute?.entities.isEmpty ?? true) {
                contentTypeHint = .animatedEmoji
            } else if messageIsEligibleForLargeEmoji(EngineMessage(message)) {
                contentTypeHint = .animatedEmoji
            }
        }
    
        if groupMessages || reverseGroupedMessages {
            if let messageGroupingKey = message.groupingKey {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
                } else {
                    selection = .none
                }
                
                var isCentered = false
                if case let .messageOptions(_, _, info) = associatedData.subject, case let .link(link) = info {
                    isCentered = link.isCentered
                }
                
                let attributes = ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: isCentered, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop)
                
                let groupStableId = currentState.messageGroupStableId(messageStableId: message.stableId, groupId: messageGroupingKey, isLocal: Namespaces.Message.allLocal.contains(message.id.namespace))
                var found = false
                for i in 0 ..< entries.count {
                    if case let .MessageEntry(currentMessage, _, currentIsRead, currentLocation, currentSelection, currentAttributes) = entries[i], let currentGroupingKey = currentMessage.groupingKey, currentState.messageGroupStableId(messageStableId: currentMessage.stableId, groupId: currentGroupingKey, isLocal: Namespaces.Message.allLocal.contains(currentMessage.id.namespace)) == groupStableId {
                        found = true
                        
                        var currentMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
                        
                        var currentAttributes = currentAttributes
                        currentAttributes.groupStableId = nil
                        currentMessages.append((currentMessage, currentIsRead, currentSelection, currentAttributes, currentLocation))
                        if reverseGroupedMessages {
                            currentMessages.insert((message, isRead, selection, attributes, entry.location), at: 0)
                        } else {
                            currentMessages.append((message, isRead, selection, attributes, entry.location))
                        }
                        
                        entries[i] = .MessageGroupEntry(groupStableId, currentMessages, presentationData)
                    } else if case let .MessageGroupEntry(currentGroupStableId, currentMessages, _) = entries[i], currentGroupStableId == groupStableId {
                        found = true
                        
                        var currentMessages = currentMessages
                        if reverseGroupedMessages {
                            currentMessages.insert((message, isRead, selection, attributes, entry.location), at: 0)
                        } else {
                            currentMessages.append((message, isRead, selection, attributes, entry.location))
                        }
                        entries[i] = .MessageGroupEntry(currentGroupStableId, currentMessages, presentationData)
                    }
                }
                if !found {
                    var attributes = attributes
                    if groupMessages {
                        // Alone so far: keep the identity of the album entry it becomes once another of
                        // the album's messages loads. Not when albums are split into messages below.
                        attributes.groupStableId = groupStableId
                    }
                    entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, attributes))
                }
            } else {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
                } else {
                    selection = .none
                }
                
                var isCentered = false
                if case let .messageOptions(_, _, info) = associatedData.subject, case let .link(link) = info {
                    isCentered = link.isCentered
                }
                
                entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: isCentered, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop)))
            }
        } else {
            let selection: ChatHistoryMessageSelection
            if let selectedMessages = selectedMessages {
                selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
            } else {
                selection = .none
            }
            
            entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop)))
        }
    }
    
    if !groupMessages && reverseGroupedMessages {
        var flatEntries: [ChatHistoryEntry] = []
        
        for entry in entries {
            switch entry {
            case let .MessageGroupEntry(_, messages, presentationData):
                for (message, isRead, selection, attributes, location) in messages {
                    flatEntries.append(.MessageEntry(message, presentationData, isRead, location, selection, attributes))
                }
            default:
                flatEntries.append(entry)
            }
        }
        entries = flatEntries
    }
    
    var addBotForumHeader = false
    if location.threadId == nil, let user = chatPeer as? TelegramUser, let botInfo = user.botInfo, botInfo.flags.contains(.hasForum), botInfo.flags.contains(.forumManagedByUser), !entries.isEmpty, !view.holeEarlier, !view.isLoading {
        addBotForumHeader = true
        outer: for i in (0 ..< entries.count).reversed() {
            switch entries[i] {
            case let .MessageEntry(message, presentationData, isRead, location, selection, attributes):
                if message.threadId == nil {
                    continue outer
                }
                for media in message.media {
                    if let _ = media as? TelegramMediaAction {
                        continue outer
                    }
                }
                var attributes = attributes
                if let subject, case .pinnedMessages = subject {
                } else {
                    attributes.displayContinueThreadFooter = true
                }
                entries[i] = .MessageEntry(message, presentationData, isRead, location, selection, attributes)
                break outer
            default:
                break
            }
        }
    }
    
    let insertPendingProcessingMessage: ([Message], Int) -> Void = { messages, index in
        let serviceMessage = Message(
            stableId: UInt32.max - messages[0].stableId,
            stableVersion: 0,
            id: MessageId(peerId: messages[0].id.peerId, namespace: -1, id: messages[0].id.id),
            globallyUniqueId: nil,
            groupingKey: nil,
            groupInfo: nil,
            threadId: nil,
            timestamp: messages[0].timestamp,
            flags: [.Incoming],
            tags: [],
            globalTags: [],
            localTags: [],
            customTags: [],
            forwardInfo: nil,
            author: nil,
            text: "",
            attributes: [],
            media: [TelegramMediaAction(action: .customText(text: presentationData.strings.Chat_VideoProcessingServiceMessage(Int32(messages.count)), entities: [], additionalAttributes: nil))],
            peers: SimpleDictionary<PeerId, Peer>(),
            associatedMessages: SimpleDictionary<MessageId, Message>(),
            associatedMessageIds: [],
            associatedMedia: [:],
            associatedThreadInfo: nil,
            associatedStories: [:]
        )
        entries.insert(.MessageEntry(serviceMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: index)
    }
    
    for i in (0 ..< entries.count).reversed() {
        switch entries[i] {
        case let .MessageEntry(message, _, _, _, _, _):
            if message.id.namespace == Namespaces.Message.ScheduledCloud && message.pendingProcessingAttribute != nil {
                insertPendingProcessingMessage([message], i)
            }
        case let .MessageGroupEntry(_, messages, _):
            if !messages.isEmpty && messages[0].0.id.namespace == Namespaces.Message.ScheduledCloud {
                var videoCount = 0
                for message in messages {
                    if message.0.pendingProcessingAttribute != nil {
                        videoCount += 1
                    }
                }
                if videoCount != 0 {
                    insertPendingProcessingMessage(messages.map(\.0), i)
                }
            }
        default:
            break
        }
    }
    
    if let lowerTimestamp = view.entries.last?.message.timestamp, let upperTimestamp = view.entries.first?.message.timestamp {
        if let joinMessage {
            var insertAtPosition: Int?
            if joinMessage.timestamp >= lowerTimestamp && view.laterId == nil {
                insertAtPosition = entries.count
            } else if joinMessage.timestamp < lowerTimestamp && joinMessage.timestamp > upperTimestamp {
                for i in 0 ..< entries.count {
                    if let timestamp = entries[i].timestamp, timestamp > joinMessage.timestamp {
                        insertAtPosition = i
                        break
                    }
                }
            }
            if let insertAtPosition {
                entries.insert(.MessageEntry(joinMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: insertAtPosition)
            }
        }
    }
        
    if let maxReadIndex = view.maxReadIndex, includeUnreadEntry {
        var i = 0
        let unreadEntry: ChatHistoryEntry = .UnreadEntry(maxReadIndex, presentationData)
        for entry in entries {
            if case let .MessageGroupEntry(_, messages, _) = entry {
                if !messages.isEmpty && maxReadIndex >= messages[0].0.index {
                    i += 1
                    continue
                }
            }
            if entry > unreadEntry {
                if i != 0 {
                    entries.insert(unreadEntry, at: i)
                }
                break
            }
            i += 1
        }
    }
    
    var addedThreadHead = false
    if case let .replyThread(replyThreadMessage) = location, !replyThreadMessage.isForumPost, view.earlierId == nil, !view.holeEarlier, !view.isLoading, !isMusicPlaylist {
        loop: for entry in view.additionalData {
            switch entry {
            case let .message(id, messages) where id == replyThreadMessage.effectiveTopId:
                if !messages.isEmpty {
                    let selection: ChatHistoryMessageSelection = .none
                    
                    let topMessage = messages[0]
                    
                    var hasTopicCreated = false
                    inner: for media in topMessage.media {
                        if let action = media as? TelegramMediaAction {
                            switch action.action {
                                case .topicCreated:
                                    hasTopicCreated = true
                                    break inner
                                default:
                                    break
                            }
                        }
                    }
                    
                    var adminRank: CachedChannelAdminRank?
                    if let author = topMessage.author {
                        adminRank = adminRanks[author.id]
                    }
                    
                    var contentTypeHint: ChatMessageEntryContentType = .generic
                    if presentationData.largeEmoji, topMessage.media.isEmpty {
                        if messageIsEligibleForLargeCustomEmoji(EngineMessage(topMessage)) {
                            contentTypeHint = .animatedEmoji
                        } else if stickersEnabled && topMessage.text.count == 1, let _ = associatedData.animatedEmojiStickers[topMessage.text.basicEmoji.0] {
                            contentTypeHint = .animatedEmoji
                        } else if messageIsEligibleForLargeEmoji(EngineMessage(topMessage)) {
                            contentTypeHint = .animatedEmoji
                        }
                    }
                    
                    addedThreadHead = true
                    if messages.count > 1, let groupingKey = messages[0].groupingKey {
                        var groupMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
                        for message in messages {
                            groupMessages.append((message, false, .none, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: false, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: false), nil))
                        }
                        entries.insert(.MessageGroupEntry(groupingKey, groupMessages, presentationData), at: 0)
                    } else {
                        if !hasTopicCreated {
                            entries.insert(.MessageEntry(messages[0], presentationData, false, nil, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[messages[0].id], isPlaying: false, isCentered: false, authorStoryStats: messages[0].author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }
                    }
                    
                    if !replyThreadMessage.isForumPost {
                        let replyCount = view.entries.isEmpty ? 0 : 1
                        entries.insert(.ReplyCountEntry(messages[0].index, replyThreadMessage.isChannelPost, replyCount, presentationData), at: 1)
                    }
                }
                break loop
            default:
                break
            }
        }
    }
    
    if includeChatInfoEntry {
        if view.earlierId == nil, !view.isLoading {
            var chatPeer: Peer?
            var cachedPeerData: CachedPeerData?
            for entry in view.additionalData {
                if case let .cachedPeerData(_, data) = entry {
                    cachedPeerData = data
                } else if case let .peer(_, peer) = entry {
                    chatPeer = peer
                }
            }
            if case let .peer(peerId) = location, peerId.isReplies {
                entries.insert(.ChatInfoEntry(.botInfo(title: "", text: presentationData.strings.RepliesChat_DescriptionText, photo: nil, video: nil, peer: nil, managedByBot: nil), presentationData), at: 0)
            } else if case let .peer(peerId) = location, peerId.isVerificationCodes {
                entries.insert(.ChatInfoEntry(.botInfo(title: "", text: presentationData.strings.VerificationCodes_DescriptionText, photo: nil, video: nil, peer: nil, managedByBot: nil), presentationData), at: 0)
            } else if let cachedPeerData = cachedPeerData as? CachedUserData {
                if let botInfo = cachedPeerData.botInfo, !botInfo.description.isEmpty {
                    if location.threadId == nil {
                        if let subject, case .pinnedMessages = subject {
                        } else {
                            entries.insert(.ChatInfoEntry(.botInfo(title: presentationData.strings.Bot_DescriptionTitle, text: botInfo.description, photo: botInfo.photo, video: botInfo.video, peer: nil, managedByBot: nil), presentationData), at: 0)
                        }
                    }
                } else if let botManagerId = cachedPeerData.botManagerId, let managedByBot = cachedPeerDataPeers[botManagerId], let peer = chatPeer.flatMap(EnginePeer.init) {
                    entries.insert(.ChatInfoEntry(.botInfo(title: "", text: "", photo: nil, video: nil, peer: peer, managedByBot: EnginePeer(managedByBot)), presentationData), at: 0)
                } else if let peerStatusSettings = cachedPeerData.peerStatusSettings, peerStatusSettings.registrationDate != nil || peerStatusSettings.phoneCountry != nil {
                    if peerStatusSettings.flags.contains(.canAddContact) || peerStatusSettings.flags.contains(.canReport) || peerStatusSettings.flags.contains(.canBlock) {
                        
                        if let chatPeer, let photoChangeDate = peerStatusSettings.photoChangeDate, photoChangeDate > 0 {
                            let timeText = stringForIntervalSinceUpdateAction(strings: presentationData.strings, value: photoChangeDate)
                            let text = presentationData.strings.Chat_NonContactUser_UpdatedPhoto(timeText)
                            var entities: [MessageTextEntity] = []
                            for range in text.ranges {
                                entities.append(MessageTextEntity(range: range.range.lowerBound ..< range.range.upperBound, type: .Bold))
                            }
                            let message = Message(
                                stableId: UInt32.max - 1001,
                                stableVersion: 0,
                                id: MessageId(peerId: chatPeer.id, namespace: Namespaces.Message.Local, id: -1),
                                globallyUniqueId: nil,
                                groupingKey: nil,
                                groupInfo: nil,
                                threadId: nil,
                                timestamp: 2,
                                flags: [.Incoming],
                                tags: [],
                                globalTags: [],
                                localTags: [],
                                customTags: [],
                                forwardInfo: nil,
                                author: chatPeer,
                                text: "",
                                attributes: [],
                                media: [TelegramMediaAction(action: .customText(
                                    text: text.string,
                                    entities: entities,
                                    additionalAttributes: nil
                                ))],
                                peers: SimpleDictionary<PeerId, Peer>(),
                                associatedMessages: SimpleDictionary<MessageId, Message>(),
                                associatedMessageIds: [],
                                associatedMedia: [:],
                                associatedThreadInfo: nil,
                                associatedStories: [:]
                            )
                            entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }
                        
                        if let chatPeer, let nameChangeDate = peerStatusSettings.nameChangeDate, nameChangeDate > 0 {
                            let timeText = stringForIntervalSinceUpdateAction(strings: presentationData.strings, value: nameChangeDate)
                            let text = presentationData.strings.Chat_NonContactUser_UpdatedName(timeText)
                            var entities: [MessageTextEntity] = []
                            for range in text.ranges {
                                entities.append(MessageTextEntity(range: range.range.lowerBound ..< range.range.upperBound, type: .Bold))
                            }
                            let message = Message(
                                stableId: UInt32.max - 1002,
                                stableVersion: 0,
                                id: MessageId(peerId: chatPeer.id, namespace: Namespaces.Message.Local, id: -2),
                                globallyUniqueId: nil,
                                groupingKey: nil,
                                groupInfo: nil,
                                threadId: nil,
                                timestamp: 1,
                                flags: [.Incoming],
                                tags: [],
                                globalTags: [],
                                localTags: [],
                                customTags: [],
                                forwardInfo: nil,
                                author: chatPeer,
                                text: "",
                                attributes: [],
                                media: [TelegramMediaAction(action: .customText(
                                    text: text.string,
                                    entities: entities,
                                    additionalAttributes: nil
                                ))],
                                peers: SimpleDictionary<PeerId, Peer>(),
                                associatedMessages: SimpleDictionary<MessageId, Message>(),
                                associatedMessageIds: [],
                                associatedMedia: [:],
                                associatedThreadInfo: nil,
                                associatedStories: [:]
                            )
                            entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }

                        if let peer = chatPeer.flatMap(EnginePeer.init) {
                            entries.insert(.ChatInfoEntry(.userInfo(peer: peer, verification: cachedPeerData.verification, registrationDate: peerStatusSettings.registrationDate, phoneCountry: peerStatusSettings.phoneCountry, groupsInCommonCount: cachedPeerData.commonGroupCount), presentationData), at: 0)
                        }
                    }
                }
            } else {
                var isEmpty = true
                if entries.count <= 3 {
                    loop: for entry in view.entries {
                        var isEmptyMedia = false
                        var isPeerJoined = false
                        for media in entry.message.media {
                            if let action = media as? TelegramMediaAction {
                                switch action.action {
                                    case .groupCreated, .photoUpdated, .channelMigratedFromGroup, .groupMigratedToChannel:
                                        isEmptyMedia = true
                                    case .peerJoined:
                                        isPeerJoined = true
                                    default:
                                        break
                                }
                            }
                        }
                        var isCreator = false
                        if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramGroup, case .creator = peer.role {
                            isCreator = true
                        } else if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramChannel, case .group = peer.info, peer.flags.contains(.isCreator) {
                            isCreator = true
                        }
                        if isPeerJoined || (isEmptyMedia && isCreator) {
                        } else {
                            isEmpty = false
                            break loop
                        }
                    }
                } else {
                    isEmpty = false
                }
                if addedThreadHead {
                    isEmpty = false
                }
                if isEmpty {
                    entries.removeAll()
                }
            }
        }
        
        if !dynamicAdMessages.isEmpty {
            assert(entries.sorted() == entries)
            for message in dynamicAdMessages {
                entries.append(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
            }
            entries.sort()
        }

        if view.laterId == nil && !view.isLoading {
            if !entries.isEmpty, case let .MessageEntry(lastMessage, _, _, _, _, _) = entries[entries.count - 1], let message = adMessage {
                var nextAdMessageId: Int32 = 10000
                let updatedMessage = Message(
                    stableId: ChatHistoryListNodeImpl.fixedAdMessageStableId,
                    stableVersion: message.stableVersion,
                    id: MessageId(peerId: message.id.peerId, namespace: message.id.namespace, id: nextAdMessageId),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: lastMessage.timestamp,
                    flags: message.flags,
                    tags: message.tags,
                    globalTags: message.globalTags,
                    localTags: message.localTags,
                    customTags: message.customTags,
                    forwardInfo: message.forwardInfo,
                    author: message.author,
                    text: /*"\(message.adAttribute!.opaqueId.hashValue)" + */message.text,
                    attributes: message.attributes,
                    media: message.media,
                    peers: message.peers,
                    associatedMessages: message.associatedMessages,
                    associatedMessageIds: message.associatedMessageIds,
                    associatedMedia: message.associatedMedia,
                    associatedThreadInfo: message.associatedThreadInfo,
                    associatedStories: message.associatedStories
                )
                nextAdMessageId += 1
                entries.append(.MessageEntry(updatedMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
            }
        }
    }
    if addBotForumHeader {
        if let subject, case .pinnedMessages = subject {
        } else {
            entries.append(.ChatInfoEntry(.newThreadInfo, presentationData))
        }
    }
    if includeEmbeddedSavedChatInfo, let peerId = location.peerId {
        if !view.isLoading && view.laterId == nil {
            let string = presentationData.strings.Chat_SavedMessagesTabInfoText
            let formattedString = parseMarkdownIntoAttributedString(
                string,
                attributes: MarkdownAttributes(
                    body: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                    bold: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                    link: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .white),
                    linkAttribute: { url in
                        return ("URL", url)
                    }
                )
            )
            var entities: [MessageTextEntity] = []
            formattedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                if let value = value as? UIColor, value == .white {
                    entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .Bold))
                }
            })
            formattedString.enumerateAttribute(NSAttributedString.Key(rawValue: "URL"), in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                if value != nil {
                    entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .TextMention(peerId: context.account.peerId)))
                }
            })
            
            let message = Message(
                stableId: UInt32.max - 1001,
                stableVersion: 0,
                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: 123),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: Int32.max - 1,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: nil,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .customText(text: formattedString.string, entities: entities, additionalAttributes: nil))],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
            entries.append(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
        }
    }
    
    if let subject = associatedData.subject, case let .customChatContents(customChatContents) = subject {
        var serviceHeaders: [String] = []
        switch customChatContents.kind {
        case let .quickReplyMessageInput(_, shortcutType):
            if case .generic = shortcutType {
                serviceHeaders = [
                    presentationData.strings.Chat_QuickReply_ServiceHeader1,
                    presentationData.strings.Chat_QuickReply_ServiceHeader2
                ]
            }
        case .welcomeMessages:
            serviceHeaders = [
                presentationData.strings.WelcomeMessages_ServiceHeader1,
                presentationData.strings.WelcomeMessages_ServiceHeader2
            ]
        case .businessLinkSetup, .hashTagSearch:
            break
        }

        if !serviceHeaders.isEmpty && !view.isLoading && view.laterId == nil && !view.entries.isEmpty {
            let peerId = view.entries[0].message.id.peerId
            for (i, string) in serviceHeaders.reversed().enumerated() {
                let formattedString = parseMarkdownIntoAttributedString(
                    string,
                    attributes: MarkdownAttributes(
                        body: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                        bold: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                        link: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .white),
                        linkAttribute: { url in
                            return ("URL", url)
                        }
                    )
                )
                var entities: [MessageTextEntity] = []
                formattedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                    if let value = value as? UIColor, value == .white {
                        entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .Bold))
                    }
                })
                formattedString.enumerateAttribute(NSAttributedString.Key(rawValue: "URL"), in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                    if value != nil {
                        entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .TextMention(peerId: context.account.peerId)))
                    }
                })
                
                let message = Message(
                    stableId: UInt32.max - 1001 - UInt32(i),
                    stableVersion: 0,
                    id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: Int32.max - 100 - Int32(i)),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: -Int32(i),
                    flags: [.Incoming],
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: nil,
                    text: "",
                    attributes: [],
                    media: [TelegramMediaAction(action: .customText(text: formattedString.string, entities: entities, additionalAttributes: nil))],
                    peers: SimpleDictionary<PeerId, Peer>(),
                    associatedMessages: SimpleDictionary<MessageId, Message>(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )
                entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
            }
        }
    }
    
    // Rows a plugin kept after the message was deleted.
    //
    // The message is gone from the database, so the list cannot be asked for it;
    // the plugin's own copy is the only source. The row is built here, marked
    // `isDeleted` so the date/status line draws the marker, and placed by its
    // original timestamp among the live rows.
    //
    // Only the loaded window is filled: a saved message older than `earlierId`
    // is not in the list yet, and inserting it at the top would put a row from
    // months ago above the messages the user actually scrolled to. Once the
    // window reaches it, the next build inserts it in place.
    if !isMusicPlaylist, location.threadId == nil, let peerId = location.peerId, !view.isLoading,
       PluginHookPoints.shared.wantsDeletedMessages?() == true,
       let deletedMessages = PluginHookPoints.shared.deletedMessages {
        let storedMessages = deletedMessages(context.account.id.int64, peerId.toInt64())
        if !storedMessages.isEmpty {
            // A saved copy of a message that is still in the chat would be a
            // second, identical row. Compared by raw id rather than by
            // `MessageId`: a live message is in the cloud namespace and the
            // saved row is placed in the local one.
            var liveMessageIds = Set<Int32>()
            for entry in view.entries where entry.message.id.peerId == peerId {
                liveMessageIds.insert(entry.message.id.id)
            }

            for storedMessage in storedMessages {
                // A copy of a message that is still in the chat would be a
                // second, identical row, and one outside the loaded window is
                // not drawn at all. Both are settled before the media is
                // decoded: this loop runs on every rebuild of the list, and
                // decoding a file description per stored message would put that
                // work on the list's build path for rows nobody will see.
                let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: storedMessage.messageId)
                if liveMessageIds.contains(storedMessage.messageId) {
                    continue
                }
                let index = MessageIndex(id: messageId, timestamp: storedMessage.timestamp)
                if let earlierId = view.earlierId, index < earlierId {
                    continue
                }
                if let laterId = view.laterId, index > laterId {
                    continue
                }

                // The media the plugin kept, if it managed to store one. A
                // sticker, photo or video comes back as the same object the
                // message carried, so the row is drawn by its ordinary node
                // instead of showing a marker.
                var storedMedia: [Media] = []
                if let media = pluginDecodedMedia(base64: storedMessage.mediaData) {
                    storedMedia.append(media)
                }

                // A copy with neither text, nor media, nor a marker has nothing
                // to show: an empty bubble would read as a message that was
                // never sent. The plugin's own list drops such an entry too.
                let displayText: String
                if !storedMessage.text.isEmpty {
                    displayText = storedMessage.text
                } else if !storedMedia.isEmpty {
                    // The media is drawn, so a caption is not needed. An empty
                    // text is what a media-only message has anyway.
                    displayText = ""
                } else if let mediaKind = storedMessage.mediaKind {
                    // No stored bytes (an older entry, or media that could not
                    // be encoded): the kind is all that is left to show.
                    displayText = "[" + mediaKind + "]"
                } else {
                    continue
                }

                var author: Peer?
                if let senderId = storedMessage.senderId, senderId != 0 {
                    let senderPeerId = PeerId(senderId)
                    if let peer = cachedPeerDataPeers[senderPeerId] {
                        author = peer
                    } else if let chatPeer, chatPeer.id == senderPeerId {
                        author = chatPeer
                    }
                }
                var peers = SimpleDictionary<PeerId, Peer>()
                if let chatPeer {
                    peers[chatPeer.id] = chatPeer
                }
                if let author {
                    peers[author.id] = author
                }

                // The same id derivation `MessageUtils` uses: it only has to
                // stay put inside one run, which is how a scroll position
                // survives a rebuild.
                var hasher = Hasher()
                hasher.combine(storedMessage.messageId)
                hasher.combine(peerId)
                let hashValue = Int64(hasher.finalize())
                let first = UInt32((hashValue >> 32) & 0xffffffff)
                let second = UInt32(hashValue & 0xffffffff)
                let stableId = first &+ second

                let message = Message(
                    stableId: stableId,
                    stableVersion: 0,
                    id: messageId,
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: storedMessage.timestamp,
                    flags: storedMessage.isOutgoing ? [] : [.Incoming],
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: author,
                    text: displayText,
                    attributes: [PluginDeletedMessageAttribute()],
                    media: storedMedia,
                    peers: peers,
                    associatedMessages: SimpleDictionary<MessageId, Message>(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )

                var attributes = ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)
                attributes.isDeleted = true

                // Selectable like any other row: the user has to be able to pick
                // a saved copy and delete it. Otherwise the row is drawn and
                // nothing can be done with it. Outside selection mode the row
                // shows `.none`, exactly as a live message does.
                let selection: ChatHistoryMessageSelection
                if let selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(messageId), num: nil)
                } else {
                    selection = .none
                }

                var insertAtPosition = entries.count
                for i in 0 ..< entries.count {
                    if entries[i].index > message.index {
                        insertAtPosition = i
                        break
                    }
                }
                entries.insert(.MessageEntry(message, presentationData, true, nil, selection, attributes), at: insertAtPosition)
            }
        }
    }

    if isMusicPlaylist && entries.count == 1 {
        return ([], currentState)
    }
    
    if reverse {
        return (entries.reversed(), currentState)
    } else {
//        #if DEBUG
//        assert(entries.map(\.stableId) == entries.sorted().map(\.stableId))
//        #endif
        return (entries, currentState)
    }
}
