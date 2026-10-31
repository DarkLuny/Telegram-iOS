import Foundation
import Postbox

/// Everything a plugin needs to know about one message, as JSON.
///
/// Two appearance hooks take a message: "how should this row animate in" and
/// "what extra rows belong in its details screen". Both are answered by
/// JavaScript, and neither may keep a Swift object alive across the bridge, so
/// the message is flattened once here and passed as a string.
///
/// The field names follow what a plugin ported from exteraGram would look for,
/// not Telegram's internal spelling: `date` rather than `timestamp`, `is_out`
/// rather than a flag bit, `media_kind` rather than a class name. Everything is
/// derived from the stored message alone, so building it never touches the
/// network and never blocks.
public func pluginMessageDetailsJSON(_ message: Message) -> String {
    var result: [String: Any] = [:]

    result["id"] = Int(message.id.id)
    result["peer_id"] = message.id.peerId.toInt64()
    result["date"] = Int(message.timestamp)
    result["namespace"] = Int(message.id.namespace)
    result["is_out"] = !message.flags.contains(.Incoming)
    result["is_unsent"] = message.flags.contains(.Unsent)
    result["is_sending"] = message.flags.contains(.Sending)
    result["is_scheduled"] = message.flags.contains(.WasScheduled)
    result["text"] = message.text

    if let author = message.author {
        result["sender_id"] = author.id.toInt64()
    }
    if let editedTime = message.editedTime {
        result["edit_date"] = Int(editedTime)
    }
    if let forwardInfo = message.forwardInfo {
        var forwarded: [String: Any] = ["date": Int(forwardInfo.date)]
        if let author = forwardInfo.author {
            forwarded["author_id"] = author.id.toInt64()
        }
        if let source = forwardInfo.source {
            forwarded["source_id"] = source.id.toInt64()
        }
        if let signature = forwardInfo.authorSignature {
            forwarded["signature"] = signature
        }
        result["forwarded"] = forwarded
    }

    for attribute in message.attributes {
        if let attribute = attribute as? ViewCountMessageAttribute {
            result["views"] = attribute.count
        } else if let attribute = attribute as? ForwardCountMessageAttribute {
            result["forwards"] = attribute.count
        } else if let attribute = attribute as? EditedMessageAttribute, attribute.isHidden {
            // A hidden edit date is a bot editing its own message; the app does
            // not show it either, and a plugin asking for "edit date" means the
            // one the user can see.
            result.removeValue(forKey: "edit_date")
        } else if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
            result["autoremove_timeout"] = Int(attribute.timeout)
            if let begin = attribute.countdownBeginTime {
                result["autoremove_expires"] = Int(begin) + Int(attribute.timeout)
            }
        }
    }

    var mediaKind = "none"
    var media: [String: Any] = [:]
    for item in message.media {
        if let file = item as? TelegramMediaFile {
            mediaKind = pluginMediaKind(file: file)
            media["mime"] = file.mimeType
            if let size = file.size {
                media["size"] = Int(size)
            }
            if let dimensions = file.dimensions {
                media["width"] = Int(dimensions.width)
                media["height"] = Int(dimensions.height)
            }
            if let datacenter = pluginDatacenterId(file.resource) {
                media["dc_id"] = datacenter
            }
            for attribute in file.attributes {
                switch attribute {
                case let .FileName(name):
                    media["file_name"] = name
                case let .Audio(isVoice, duration, title, performer, waveform):
                    media["duration"] = duration
                    media["is_voice"] = isVoice
                    if let title = title {
                        media["title"] = title
                    }
                    if let performer = performer {
                        media["performer"] = performer
                    }
                    if let waveform = waveform {
                        media["waveform_length"] = waveform.count
                    }
                case let .Video(duration, size, _, _, _, codec):
                    media["duration"] = Int(duration)
                    media["width"] = Int(size.width)
                    media["height"] = Int(size.height)
                    if let codec = codec {
                        media["codec"] = codec
                    }
                case let .Sticker(displayText, packReference, _):
                    media["emoji"] = displayText
                    if let packReference = packReference {
                        media["sticker_pack"] = pluginStickerPackJSON(packReference)
                    }
                case let .CustomEmoji(_, _, alt, packReference):
                    media["emoji"] = alt
                    if let packReference = packReference {
                        media["sticker_pack"] = pluginStickerPackJSON(packReference)
                    }
                case .Animated:
                    media["animated"] = true
                case let .ImageSize(size):
                    media["width"] = Int(size.width)
                    media["height"] = Int(size.height)
                default:
                    break
                }
            }
        } else if let image = item as? TelegramMediaImage {
            mediaKind = "photo"
            var best = PixelDimensions(width: 0, height: 0)
            for representation in image.representations {
                if representation.dimensions.width >= best.width && representation.dimensions.height >= best.height {
                    best = representation.dimensions
                }
                if let datacenter = pluginDatacenterId(representation.resource) {
                    media["dc_id"] = datacenter
                }
            }
            if best.width > 0, best.height > 0 {
                media["width"] = Int(best.width)
                media["height"] = Int(best.height)
            }
        } else if let poll = item as? TelegramMediaPoll {
            mediaKind = "poll"
            var pollJSON: [String: Any] = [
                "question": poll.text,
                "is_closed": poll.isClosed,
                "options": poll.options.count
            ]
            switch poll.publicity {
            case .anonymous:
                pollJSON["public_voters"] = false
            case .public:
                pollJSON["public_voters"] = true
            }
            switch poll.kind {
            case let .poll(multipleAnswers):
                pollJSON["quiz"] = false
                pollJSON["multiple_choice"] = multipleAnswers
            case let .quiz(multipleAnswers):
                pollJSON["quiz"] = true
                pollJSON["multiple_choice"] = multipleAnswers
            }
            pollJSON["add_options"] = poll.openAnswers
            pollJSON["allow_revoting"] = !poll.revotingDisabled
            pollJSON["shuffle_options"] = poll.shuffleAnswers
            if let deadline = poll.deadlineTimeout {
                pollJSON["duration_limit"] = Int(deadline)
            }
            if let date = poll.deadlineDate {
                pollJSON["close_date"] = Int(date)
            }
            if let voters = poll.results.totalVoters {
                pollJSON["total_voters"] = Int(voters)
            }
            if let solution = poll.results.solution {
                pollJSON["solution"] = solution.text
            }
            media["poll"] = pollJSON
        } else if let action = item as? TelegramMediaAction {
            mediaKind = "service"
            media["action"] = pluginActionName(action.action)
        } else if item is TelegramMediaWebpage {
            mediaKind = "webpage"
        } else if let dice = item as? TelegramMediaDice {
            mediaKind = "dice"
            media["emoji"] = dice.emoji
            // `value` is optional until the animation has been revealed; an
            // optional inside the dictionary would make the whole document
            // unencodable, so it is only added when it is actually known.
            if let value = dice.value {
                media["value"] = value
            }
        } else if let contact = item as? TelegramMediaContact {
            mediaKind = "contact"
            media["first_name"] = contact.firstName
            media["last_name"] = contact.lastName
            media["phone_number"] = contact.phoneNumber
        } else if let location = item as? TelegramMediaMap {
            mediaKind = "location"
            media["latitude"] = location.latitude
            media["longitude"] = location.longitude
        } else if let story = item as? TelegramMediaStory {
            mediaKind = "story"
            media["story_peer"] = story.storyId.peerId.toInt64()
        }
    }

    result["media_kind"] = mediaKind
    if !media.isEmpty {
        result["media"] = media
    }

    return pluginJSONString(result)
}

/// The media kind a details screen groups by.
private func pluginMediaKind(file: TelegramMediaFile) -> String {
    if file.isCustomEmoji {
        return "custom_emoji"
    }
    if file.isSticker {
        if file.isVideoSticker {
            return "sticker_video"
        } else if file.isAnimatedSticker {
            return "sticker_animated"
        }
        return "sticker"
    }
    if file.isVoice {
        return "voice"
    }
    if file.isMusic {
        return "music"
    }
    if file.isInstantVideo {
        return "round_video"
    }
    if file.isAnimated, !file.isVideo {
        return "gif"
    }
    if file.isVideo {
        return "video"
    }
    if file.isAnimated {
        return "gif"
    }
    for attribute in file.attributes {
        if case .ImageSize = attribute {
            return "photo_file"
        }
    }
    return "file"
}

/// The datacenter a resource lives in, or `nil` for a local one.
///
/// A details screen shows "DC4"; a locally generated resource has no datacenter,
/// so the row is omitted rather than printed as `DC0`.
private func pluginDatacenterId(_ resource: TelegramMediaResource) -> Int? {
    if let resource = resource as? CloudFileMediaResource {
        return resource.datacenterId
    }
    if let resource = resource as? CloudDocumentMediaResource {
        return resource.datacenterId
    }
    if let resource = resource as? CloudPhotoSizeMediaResource {
        return resource.datacenterId
    }
    if let resource = resource as? CloudPeerPhotoSizeMediaResource {
        return resource.datacenterId
    }
    return nil
}

private func pluginStickerPackJSON(_ reference: StickerPackReference) -> [String: Any] {
    switch reference {
    case let .id(id, _):
        return ["id": id]
    case let .name(name):
        return ["short_name": name]
    case .animatedEmoji, .animatedEmojiAnimations, .emojiGenericAnimations:
        return ["short_name": "animated_emoji"]
    case let .dice(emoji):
        return ["short_name": "dice", "emoji": emoji]
    case .premiumGifts, .tonGifts:
        return ["short_name": "gifts"]
    case .iconStatusEmoji:
        return ["short_name": "status_emoji"]
    case .iconTopicEmoji:
        return ["short_name": "topic_emoji"]
    case .iconChannelStatusEmoji:
        return ["short_name": "channel_status_emoji"]
    }
}

/// The action a service message performs, spelled the way a details row names it.
///
/// Only the kinds a details screen singles out are mapped by hand. Everything
/// else keeps the enum's own name, which is already stable and readable, so a
/// newly added action needs no change here.
private func pluginActionName(_ action: TelegramMediaActionType) -> String {
    switch action {
    case .groupCreated:
        return "group_created"
    case .addedMembers:
        return "added_members"
    case .removedMembers:
        return "removed_members"
    case .channelMigratedFromGroup:
        return "channel_migrated_from_group"
    case .groupMigratedToChannel:
        return "group_migrated_to_channel"
    case .photoUpdated:
        return "photo_updated"
    case .titleUpdated:
        return "title_updated"
    case .pinnedMessageUpdated:
        return "pinned_message"
    case .joinedByRequest:
        return "joined_by_request"
    case .joinedByLink:
        return "joined_by_link"
    case .groupPhoneCall:
        return "group_call"
    case .phoneCall:
        return "phone_call"
    case .gameScore:
        return "game_score"
    case .historyCleared:
        return "history_cleared"
    case .historyScreenshot:
        return "screenshot_taken"
    case .messageAutoremoveTimeoutUpdated:
        return "autoremove_updated"
    case .paymentSent:
        return "payment_sent"
    case .customText:
        return "custom_text"
    case .botDomainAccessGranted:
        return "bot_domain_access"
    case .botAppAccessGranted:
        return "bot_app_access"
    default:
        // No payload and no free-form text: an unknown action is reported as a
        // plain service message rather than by dumping its associated values,
        // which can hold a member list or user-written text.
        return "service"
    }
}