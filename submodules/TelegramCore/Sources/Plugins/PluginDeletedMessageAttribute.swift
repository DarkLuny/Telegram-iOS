import Foundation
import Postbox

/// Marks the row a plugin restored for a message that has been deleted.
///
/// The row is synthesized in `ChatHistoryEntriesForView` and exists only in
/// the list: there is no stored message behind it. Several places decide what
/// to do with a message by asking the database — opening a voice message
/// queues it from history, the gallery looks its media up by id, a local
/// namespace row is assumed to be pending. All of them would either find
/// nothing or refuse, so each has to recognise this one kind of row.
///
/// The namespace cannot carry that meaning: `Local` is also where unsent
/// messages and media uploads live. A dedicated attribute says exactly what
/// this is, and travels with the message into every function that takes one.
public final class PluginDeletedMessageAttribute: MessageAttribute {
    public init() {
    }

    required public init(decoder: PostboxDecoder) {
    }

    public func encode(_ encoder: PostboxEncoder) {
        // Nothing to store: the row itself is never written to the database,
        // this is only here to satisfy `PostboxCoding`.
    }
}

public extension Message {
    var isPluginRestoredDeletedMessage: Bool {
        for attribute in self.attributes {
            if attribute is PluginDeletedMessageAttribute {
                return true
            }
        }
        return false
    }
}