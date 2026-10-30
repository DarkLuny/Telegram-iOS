/*
 * exteraGram-compatible plugin bootstrap for Telegram iOS.
 *
 * This file is not shipped as a resource: `PluginBootstrap.swift` embeds it as a
 * string and evaluates it in every plugin's JSContext before the plugin source.
 * Keeping it here lets `node js/test` run the same code the app runs.
 *
 * The host (Swift) provides a single object, `__host`, with these members:
 *
 *   __host.log(pluginId, text)
 *   __host.getSetting(pluginId, key)
 *   __host.setSetting(pluginId, key, value, reload)
 *   __host.exportSettings(pluginId) / importSettings(pluginId, values, reload)
 *   __host.addHook(pluginId, name, matchSubstring)
 *   __host.addOnSendMessageHook(pluginId)
 *   __host.addMenuItem(pluginId, itemJson) -> itemId
 *   __host.removeMenuItem(pluginId, itemId)
 *   __host.sendText(pluginId, account, peerId, text, optionsJson)
 *   __host.sendFile(pluginId, account, kind, peerId, path, optionsJson)
 *   __host.editMessage(pluginId, account, peerId, messageId, text, optionsJson)
 *   __host.showBulletin(pluginId, kind, json)
 *   __host.showAlert(pluginId, json)
 *   __host.fileOp(pluginId, op, path, payload) -> json
 *   __host.selectedAccount(pluginId)
 *   __host.copyToClipboard(pluginId, text)
 *   __host.pluginDirectory(pluginId)
 *   __host.schedulePlugin(pluginId, delayMs, token)
 *
 * `js/test/bootstrap.test.js` installs a fake `__host` with exactly this shape,
 * so a bridge the bootstrap calls but the test does not provide fails there
 * instead of on a device.
 *
 * The API surface mirrors exteraGram's Python SDK (BasePlugin, HookResult,
 * HookStrategy, MenuItemData, MenuItemType, AppEvent, the ui.settings controls)
 * because that is the contract plugin authors already know. The Python runtime
 * itself cannot exist on iOS: exteraGram's plugins reach into Java classes via
 * reflection and Xposed hooks, and there are no Java classes here. What maps is
 * the shape of the API, not the implementation.
 */

var __extera = (function () {
    'use strict';

    var pluginId = null;
    var pluginName = null;
    var registeredHooks = [];
    var sendHookEnabled = false;
    var menuItems = {};
    // Compiled string `condition`s of menu items, keyed by the context shape plus
    // the expression, so a menu reopened with the same keys reuses one function.
    var compiledConditions = {};
    var scheduled = {};
    var scheduledCounter = 0;
    // The account a hook callback is running for, so `get_hook_account()` and a
    // bare `self.client()` see the account exteraGram would give them. Set around
    // every callback and restored afterwards, because callbacks can nest (a hook
    // that sends a message re-enters the send hook).
    var hookAccount = null;
    var hookAccountStack = [];
    // Consecutive numeric account ids (0, 1, 2 ...) are an exteraGram concept:
    // there the accounts are indices. The host resolves them, so a plugin that
    // hardcodes `account=0` still works; these helpers only pass them through.
    var selectedAccount = 0;

    function host() {
        return __host;
    }

    function bridgeMissing(name) {
        var h = host();
        if (!h || typeof h[name] !== 'function') {
            throw new Error('host bridge is missing ' + name);
        }
        return h[name].bind(h);
    }

    function hasBridge(name) {
        var h = host();
        return !!h && typeof h[name] === 'function';
    }

    // exteraGram runs every callback inside an "account scope": the account the
    // hook fired for. Anything the callback calls then defaults to that account
    // instead of the one selected in the UI. The same idea here, minus the
    // warning log: `hookAccount` is what `get_hook_account()` returns.
    function withHookAccount(account, body) {
        hookAccountStack.push(hookAccount);
        if (account !== undefined && account !== null) {
            hookAccount = account;
        }
        try {
            return body();
        } finally {
            hookAccount = hookAccountStack.pop();
        }
    }

    function currentAccount(explicit) {
        if (explicit !== undefined && explicit !== null) {
            return explicit;
        }
        if (hookAccount !== null && hookAccount !== undefined) {
            return hookAccount;
        }
        return selectedAccount;
    }

    // --- HTML / Markdown text parsing ------------------------------------
    //
    // exteraGram parses formatting on the Python side and hands Telegram plain
    // text plus entities. iOS has no HTML message parser in the app layer (the
    // composer only pastes Markdown), so both modes are parsed here: one
    // implementation, testable with node, used by `parse_text` and by every
    // `send_*` that takes `parse_mode`.
    //
    // An entity is `{type, offset, length, ...extras}` where `type` is a
    // `TLEntityType` value. Offsets are UTF-16 units, which is what JavaScript
    // and the host's string indexing agree on.

    var TLEntityType = {
        BOLD: 'bold',
        ITALIC: 'italic',
        UNDERLINE: 'underline',
        STRIKETHROUGH: 'strikethrough',
        SPOILER: 'spoiler',
        CODE: 'code',
        PRE: 'pre',
        TEXT_LINK: 'text_link',
        BLOCKQUOTE: 'blockquote',
        CUSTOM_EMOJI: 'custom_emoji',
    };

    function sortEntities(entities) {
        entities.sort(function (a, b) {
            if (a.offset !== b.offset) { return a.offset - b.offset; }
            return b.length - a.length;
        });
        return entities;
    }

    function pushEntity(list, type, offset, length, extras) {
        if (length <= 0) {
            return;
        }
        var entity = { type: type, offset: offset, length: length };
        if (extras) {
            for (var key in extras) {
                if (Object.prototype.hasOwnProperty.call(extras, key)) {
                    entity[key] = extras[key];
                }
            }
        }
        list.push(entity);
    }

    // Standard named references plus numeric ones. Telegram's HTML parse mode
    // accepts the XML five and numeric escapes; anything else stays literal, as
    // it does there.
    var NAMED_REFERENCES = {
        amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
    };

    function decodeReferences(text) {
        if (text.indexOf('&') < 0) {
            return text;
        }
        return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, function (match, body) {
            if (body.charAt(0) === '#') {
                var isHex = body.charAt(1) === 'x' || body.charAt(1) === 'X';
                var digits = isHex ? body.slice(2) : body.slice(1);
                var code = parseInt(digits, isHex ? 16 : 10);
                if (!isFinite(code) || code <= 0 || code > 0x10ffff) {
                    return match;
                }
                try {
                    return String.fromCodePoint(code);
                } catch (error) {
                    return match;
                }
            }
            var named = NAMED_REFERENCES[body.toLowerCase()];
            return named === undefined ? match : named;
        });
    }

    function parseAttributes(body) {
        var result = {};
        var regex = /([a-zA-Z_][a-zA-Z0-9_-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
        var match;
        while ((match = regex.exec(body)) !== null) {
            var value = match[3];
            if (value === undefined) { value = match[4]; }
            if (value === undefined) { value = match[5]; }
            result[match[1].toLowerCase()] = decodeReferences(value === undefined ? '' : value);
        }
        return result;
    }

    // Which HTML tags map to which entity, and whether they take extras.
    var HTML_TAGS = {
        b: { type: TLEntityType.BOLD },
        strong: { type: TLEntityType.BOLD },
        i: { type: TLEntityType.ITALIC },
        em: { type: TLEntityType.ITALIC },
        u: { type: TLEntityType.UNDERLINE },
        ins: { type: TLEntityType.UNDERLINE },
        s: { type: TLEntityType.STRIKETHROUGH },
        del: { type: TLEntityType.STRIKETHROUGH },
        strike: { type: TLEntityType.STRIKETHROUGH },
        code: { type: TLEntityType.CODE },
        pre: { type: TLEntityType.PRE, language: true },
        'tg-spoiler': { type: TLEntityType.SPOILER },
        spoiler: { type: TLEntityType.SPOILER },
        blockquote: { type: TLEntityType.BLOCKQUOTE, collapsed: true },
        a: { type: TLEntityType.TEXT_LINK, href: true },
        emoji: { type: TLEntityType.CUSTOM_EMOJI, emojiId: true },
    };

    function parseHTML(input, isCaption) {
        var text = '';
        var entities = [];
        var stack = [];
        var index = 0;

        while (index < input.length) {
            var lt = input.indexOf('<', index);
            if (lt < 0) {
                text += decodeReferences(input.slice(index));
                break;
            }
            text += decodeReferences(input.slice(index, lt));
            var gt = input.indexOf('>', lt);
            if (gt < 0) {
                // An unterminated tag is literal text, which is also what
                // Telegram does rather than rejecting the whole message.
                text += decodeReferences(input.slice(lt));
                break;
            }
            var rawTag = input.slice(lt + 1, gt).trim();
            index = gt + 1;

            if (rawTag === '') {
                continue;
            }
            if (rawTag.charAt(0) === '/') {
                var closing = rawTag.slice(1).trim().toLowerCase();
                // Pop to the matching tag so a mismatched close cannot swallow
                // an outer one; an unmatched close is ignored.
                for (var depth = stack.length - 1; depth >= 0; depth -= 1) {
                    if (stack[depth].tag === closing) {
                        var open = stack[depth];
                        stack.length = depth;
                        pushEntity(entities, open.type, open.start, text.length - open.start, open.extras);
                        break;
                    }
                }
                continue;
            }

            var selfClosing = rawTag.charAt(rawTag.length - 1) === '/';
            if (selfClosing) {
                rawTag = rawTag.slice(0, -1).trim();
            }
            var space = rawTag.search(/\s/);
            var name = (space < 0 ? rawTag : rawTag.slice(0, space)).toLowerCase();
            var attributes = space < 0 ? {} : parseAttributes(rawTag.slice(space + 1));

            if (name === 'br') {
                text += '\n';
                continue;
            }
            var spec = HTML_TAGS[name];
            if (!spec) {
                // Unknown tags are formatting exteraGram does not support
                // either; the content still counts, the tag does not.
                continue;
            }
            var extras;
            if (spec.type === TLEntityType.TEXT_LINK) {
                if (!attributes.href) {
                    continue;
                }
                extras = { url: attributes.href };
            } else if (spec.language) {
                extras = attributes.language ? { language: attributes.language } : null;
            } else if (spec.collapsed) {
                var collapsed = attributes.collapsed === 'true' || attributes.expandable === 'false';
                extras = { collapsed: collapsed };
            } else if (spec.emojiId) {
                var emojiId = attributes.id || attributes['document-id'] || '';
                extras = { document_id: emojiId };
            }
            if (selfClosing) {
                pushEntity(entities, spec.type, text.length, 0, extras);
                continue;
            }
            stack.push({ tag: name, type: spec.type, start: text.length, extras: extras });
        }

        // Unclosed tags end at the end of the text, which is what a reader of the
        // message would assume.
        for (var i = 0; i < stack.length; i += 1) {
            pushEntity(entities, stack[i].type, stack[i].start, text.length - stack[i].start, stack[i].extras);
        }

        sortEntities(entities);
        return { text: text, entities: entities };
    }

    // Finds `marker` at or after `from`, skipping over escaped characters.
    function findMarker(input, marker, from) {
        var index = from;
        while (index < input.length) {
            var found = input.indexOf(marker, index);
            if (found < 0) {
                return -1;
            }
            if (found > 0 && input.charAt(found - 1) === '\\') {
                index = found + marker.length;
                continue;
            }
            return found;
        }
        return -1;
    }

    function unescapeMarkdown(text) {
        return text.replace(/\\([\\_*~`|\[\]()>#+\-.!])/g, '$1');
    }

    // Delimiters in the order they must be tried: a longer marker shares a
    // prefix with a shorter one, and `__` before `_` keeps underline from being
    // read as two italic spans.
    var MARKDOWN_DELIMITERS = [
        { marker: '||', type: TLEntityType.SPOILER },
        { marker: '__', type: TLEntityType.UNDERLINE },
        { marker: '**', type: TLEntityType.BOLD },
        { marker: '~~', type: TLEntityType.STRIKETHROUGH },
        { marker: '~', type: TLEntityType.STRIKETHROUGH },
        { marker: '*', type: TLEntityType.BOLD },
        { marker: '_', type: TLEntityType.ITALIC },
    ];

    function parseMarkdown(input) {
        var text = '';
        var entities = [];

        function emit(segment, offset) {
            // A recursive call returns text already unescaped and its own
            // entities relative to itself; shift them into place.
            text += segment.text;
            for (var i = 0; i < segment.entities.length; i += 1) {
                var entity = segment.entities[i];
                var shifted = { type: entity.type, offset: entity.offset + offset, length: entity.length };
                for (var key in entity) {
                    if (Object.prototype.hasOwnProperty.call(entity, key) && key !== 'type' && key !== 'offset' && key !== 'length') {
                        shifted[key] = entity[key];
                    }
                }
                entities.push(shifted);
            }
        }

        var index = 0;
        var lineStart = true;
        while (index < input.length) {
            // Fenced code block: ```lang ... ```
            if (input.substr(index, 3) === '```') {
                var fenceEnd = findMarker(input, '```', index + 3);
                if (fenceEnd >= 0) {
                    var body = input.slice(index + 3, fenceEnd);
                    var language = '';
                    var newline = body.indexOf('\n');
                    if (newline >= 0) {
                        language = body.slice(0, newline).trim();
                        body = body.slice(newline + 1);
                    }
                    var preOffset = text.length;
                    text += body;
                    pushEntity(entities, TLEntityType.PRE, preOffset, body.length, language ? { language: language } : null);
                    index = fenceEnd + 3;
                    lineStart = false;
                    continue;
                }
            }

            // Inline code wins over every other marker, as in Telegram.
            if (input.charAt(index) === '`') {
                var codeEnd = findMarker(input, '`', index + 1);
                if (codeEnd >= 0) {
                    var code = input.slice(index + 1, codeEnd);
                    var codeOffset = text.length;
                    text += code;
                    pushEntity(entities, TLEntityType.CODE, codeOffset, code.length, null);
                    index = codeEnd + 1;
                    lineStart = false;
                    continue;
                }
            }

            // Custom emoji: ![alt](tg://emoji?id=123)
            if (input.substr(index, 2) === '![' && input.charAt(index + 2) !== undefined) {
                var emojiClose = input.indexOf('](', index + 2);
                var emojiEnd = emojiClose < 0 ? -1 : input.indexOf(')', emojiClose + 2);
                if (emojiClose >= 0 && emojiEnd >= 0) {
                    var emojiUrl = input.slice(emojiClose + 2, emojiEnd);
                    var idMatch = /[?&]id=([0-9]+)/.exec(emojiUrl);
                    if (idMatch) {
                        var alt = input.slice(index + 2, emojiClose);
                        var emojiOffset = text.length;
                        text += alt;
                        pushEntity(entities, TLEntityType.CUSTOM_EMOJI, emojiOffset, alt.length, { document_id: idMatch[1] });
                        index = emojiEnd + 1;
                        lineStart = false;
                        continue;
                    }
                }
            }

            // Link: [text](url)
            if (input.charAt(index) === '[') {
                var linkClose = input.indexOf('](', index + 1);
                var linkEnd = linkClose < 0 ? -1 : input.indexOf(')', linkClose + 2);
                if (linkClose >= 0 && linkEnd >= 0) {
                    var url = input.slice(linkClose + 2, linkEnd).trim();
                    var label = input.slice(index + 1, linkClose);
                    var linkOffset = text.length;
                    var inner = parseMarkdown(label);
                    text += inner.text;
                    for (var innerIndex = 0; innerIndex < inner.entities.length; innerIndex += 1) {
                        var innerEntity = inner.entities[innerIndex];
                        innerEntity.offset += linkOffset;
                        entities.push(innerEntity);
                    }
                    pushEntity(entities, TLEntityType.TEXT_LINK, linkOffset, inner.text.length, { url: url });
                    index = linkEnd + 1;
                    lineStart = false;
                    continue;
                }
            }

            // Quote: `> line` (and `**> line` for an expandable one). Only at the
            // start of a line, which is where Telegram recognises it.
            if (lineStart) {
                var remaining = input.slice(index);
                var quoteMatch = /^(\*\*)?>[ \t]?/.exec(remaining);
                if (quoteMatch) {
                    var collapsed = !quoteMatch[1];
                    var afterMarker = index + quoteMatch[0].length;
                    var lineEnd = input.indexOf('\n', afterMarker);
                    if (lineEnd < 0) { lineEnd = input.length; }
                    var quoteBody = input.slice(afterMarker, lineEnd);
                    var quoteOffset = text.length;
                    var parsedQuote = parseMarkdown(quoteBody);
                    text += parsedQuote.text;
                    for (var quoteIndex = 0; quoteIndex < parsedQuote.entities.length; quoteIndex += 1) {
                        var quoteEntity = parsedQuote.entities[quoteIndex];
                        quoteEntity.offset += quoteOffset;
                        entities.push(quoteEntity);
                    }
                    pushEntity(entities, TLEntityType.BLOCKQUOTE, quoteOffset, parsedQuote.text.length, { collapsed: collapsed });
                    index = lineEnd;
                    continue;
                }
            }

            // Paired emphasis markers.
            var matched = false;
            for (var delimiterIndex = 0; delimiterIndex < MARKDOWN_DELIMITERS.length; delimiterIndex += 1) {
                var delimiter = MARKDOWN_DELIMITERS[delimiterIndex];
                if (input.substr(index, delimiter.marker.length) !== delimiter.marker) {
                    continue;
                }
                // `_` inside a word is a literal underscore, not emphasis.
                if (delimiter.marker === '_' && index > 0 && /[A-Za-z0-9]/.test(input.charAt(index - 1))) {
                    continue;
                }
                var close = findMarker(input, delimiter.marker, index + delimiter.marker.length);
                if (close < 0 || close === index + delimiter.marker.length) {
                    continue;
                }
                var emphasisContent = input.slice(index + delimiter.marker.length, close);
                var emphasisOffset = text.length;
                var parsedEmphasis = parseMarkdown(emphasisContent);
                text += parsedEmphasis.text;
                for (var emphasisIndex = 0; emphasisIndex < parsedEmphasis.entities.length; emphasisIndex += 1) {
                    var emphasisEntity = parsedEmphasis.entities[emphasisIndex];
                    emphasisEntity.offset += emphasisOffset;
                    entities.push(emphasisEntity);
                }
                pushEntity(entities, delimiter.type, emphasisOffset, parsedEmphasis.text.length, null);
                index = close + delimiter.marker.length;
                matched = true;
                lineStart = false;
                break;
            }
            if (matched) {
                continue;
            }

            var character = input.charAt(index);
            if (character === '\\' && index + 1 < input.length) {
                var escaped = input.charAt(index + 1);
                text += escaped;
                index += 2;
                lineStart = escaped === '\n';
                continue;
            }
            text += character;
            index += 1;
            lineStart = character === '\n';
        }

        sortEntities(entities);
        return { text: unescapeMarkdown(text), entities: entities };
    }

    // `parse_text(text, parse_mode="HTML", is_caption=False)` from
    // `extera_utils.text_formatting`. HTML is the default, as in the SDK.
    function parseText(text, parseMode, isCaption) {
        var source = text === undefined || text === null ? '' : String(text);
        var mode = (parseMode === undefined || parseMode === null ? 'HTML' : String(parseMode)).toLowerCase();
        var parsed = mode === 'markdown' || mode === 'md' || mode === 'markdownv2'
            ? parseMarkdown(source)
            : parseHTML(source);
        var result = { entities: parsed.entities };
        result[isCaption ? 'caption' : 'message'] = parsed.text;
        return result;
    }

    // Text plus entities for one `send_*` call. When the plugin asked for
    // `parse_mode`, the formatting is stripped and turned into entities here;
    // otherwise the text goes through as typed and the host detects bare links
    // and mentions itself. Doing the parse on this side means the HTML/Markdown
    // implementation is the same one `parse_text` uses, instead of a second
    // converter in Swift with its own set of supported tags.
    function prepareText(text, options) {
        var source = text === undefined || text === null ? '' : String(text);
        var mode = options && options.parse_mode ? String(options.parse_mode) : null;
        if (!mode) {
            return { text: source, entities: [] };
        }
        var parsed = parseText(source, mode, false);
        return { text: parsed.message, entities: parsed.entities };
    }

    // Caption handling for the media helpers: `caption` plus the same
    // `parse_mode` the text helpers take. The result goes back onto the options
    // object as plain text and entities, so the host does not parse a second time.
    function captionFor(options) {
        var caption = options.caption;
        if (caption === undefined || caption === null) {
            return null;
        }
        var payload = prepareText(caption, options);
        options.caption_entities = payload.entities;
        return payload.text;
    }

    // --- deferred callbacks ----------------------------------------------
    //
    // A JS function cannot cross the string-only bridge, so any API that takes a
    // callback and completes later (a bulletin button, an alert button) stores
    // the function here and hands the host a token. The host calls
    // `__extera.runCallback(token, argsJSON)` when the user acts.

    var heldCallbacks = {};
    var heldCounter = 0;

    function holdCallback(fn) {
        if (typeof fn !== 'function') {
            return null;
        }
        heldCounter += 1;
        var token = 'c' + heldCounter;
        heldCallbacks[token] = fn;
        return token;
    }

    function runCallback(token, argsJSON) {
        var fn = heldCallbacks[token];
        if (typeof fn !== 'function') {
            return null;
        }
        // One-shot: a dismissed dialog or a consumed bulletin must not keep the
        // closure (and whatever it captured) alive.
        delete heldCallbacks[token];
        var args = argsJSON ? JSON.parse(argsJSON) : [];
        var result = fn.apply(null, args);
        if (result === undefined || result === null) {
            return null;
        }
        return JSON.stringify(result);
    }

    // --- ui.alert ---------------------------------------------------------
    //
    // `AlertDialogBuilder` is a builder in exteraGram: setters accumulate state,
    // `show()` displays it. The host receives the accumulated state in one
    // object, with button callbacks replaced by tokens.

    function AlertDialogBuilder(activity, progressStyle) {
        if (!(this instanceof AlertDialogBuilder)) {
            return new AlertDialogBuilder(activity, progressStyle);
        }
        // The `activity` argument exists so a ported `AlertDialogBuilder(fragment
        // .getParentActivity())` keeps its shape; nothing on iOS needs it.
        this.type = progressStyle === undefined ? AlertDialogBuilder.ALERT_TYPE_MESSAGE : progressStyle;
        this._title = null;
        this._message = null;
        this._items = null;
        this._buttons = { positive: null, negative: null, neutral: null };
        this._cancelable = true;
        this._dismissed = false;
        this._cancelToken = null;
        this._dismissToken = null;
    }

    AlertDialogBuilder.ALERT_TYPE_MESSAGE = 0;
    AlertDialogBuilder.ALERT_TYPE_LOADING = 1;
    AlertDialogBuilder.ALERT_TYPE_SPINNER = 2;
    AlertDialogBuilder.BUTTON_POSITIVE = -1;
    AlertDialogBuilder.BUTTON_NEGATIVE = -2;
    AlertDialogBuilder.BUTTON_NEUTRAL = -3;

    function addButton(self, role, text, listener) {
        self._buttons[role] = {
            text: String(text),
            token: holdCallback(listener),
        };
        return self;
    }

    AlertDialogBuilder.prototype.set_title = function (title) {
        this._title = String(title);
        return this;
    };
    AlertDialogBuilder.prototype.set_message = function (message) {
        this._message = String(message);
        return this;
    };
    AlertDialogBuilder.prototype.set_items = function (items, listener) {
        var list = [];
        for (var i = 0; i < (items || []).length; i += 1) {
            list.push(String(items[i]));
        }
        this._items = { values: list, token: holdCallback(listener) };
        return this;
    };
    AlertDialogBuilder.prototype.set_positive_button = function (text, listener) {
        return addButton(this, 'positive', text, listener);
    };
    AlertDialogBuilder.prototype.set_negative_button = function (text, listener) {
        return addButton(this, 'negative', text, listener);
    };
    AlertDialogBuilder.prototype.set_neutral_button = function (text, listener) {
        return addButton(this, 'neutral', text, listener);
    };
    AlertDialogBuilder.prototype.set_on_cancel_listener = function (listener) {
        this._cancelToken = holdCallback(listener);
        return this;
    };
    AlertDialogBuilder.prototype.set_on_dismiss_listener = function (listener) {
        this._dismissToken = holdCallback(listener);
        return this;
    };
    AlertDialogBuilder.prototype.set_cancelable = function (cancelable) {
        this._cancelable = !!cancelable;
        return this;
    };
    AlertDialogBuilder.prototype.set_canceled_on_touch_outside = function (cancel) {
        this._cancelable = !!cancel;
        return this;
    };
    AlertDialogBuilder.prototype.set_progress = function (progress) {
        this._progress = progress;
        return this;
    };
    // Appearance setters that have no iOS counterpart are accepted and ignored
    // rather than throwing: a ported dialog still shows, just plainer.
    ['make_button_red', 'set_message_text_view_clickable', 'set_view',
     'set_top_image', 'set_top_drawable', 'set_top_animation', 'set_dim_enabled',
     'set_dialog_button_color_key', 'set_blurred_background',
     'set_on_back_button_listener'].forEach(function (name) {
        AlertDialogBuilder.prototype[name] = function () {
            return this;
        };
    });
    AlertDialogBuilder.prototype.create = function () {
        return this;
    };
    AlertDialogBuilder.prototype.get_dialog = function () {
        return this._dismissed ? null : this;
    };
    AlertDialogBuilder.prototype.get_button = function () {
        return null;
    };
    AlertDialogBuilder.prototype.show = function () {
        if (this._dismissed) {
            return this;
        }
        // The negative/neutral/positive roles are stable strings so the host can
        // pick the UIKit role without knowing exteraGram's integer constants.
        var buttons = [];
        ['negative', 'neutral', 'positive'].forEach(function (role) {
            var button = this._buttons[role];
            if (button && button.text) {
                buttons.push({ role: role, text: button.text, token: button.token });
            }
        }, this);
        bridgeMissing('showAlert')(pluginId, JSON.stringify({
            title: this._title,
            message: this._message,
            items: this._items ? this._items.values : null,
            items_token: this._items ? this._items.token : null,
            buttons: buttons,
            cancelable: this._cancelable,
            spinner: this.type === AlertDialogBuilder.ALERT_TYPE_SPINNER,
            progress: typeof this._progress === 'number' ? this._progress : null,
            cancel_token: this._cancelToken,
            dismiss_token: this._dismissToken,
        }));
        return this;
    };
    AlertDialogBuilder.prototype.dismiss = function () {
        this._dismissed = true;
        bridgeMissing('dismissAlert')(pluginId);
        return this;
    };

    // --- enums ------------------------------------------------------------

    var HookStrategy = {
        DEFAULT: 'default',
        CANCEL: 'cancel',
        MODIFY: 'modify',
        MODIFY_FINAL: 'modify_final',
    };

    var AppEvent = {
        START: 'start',
        STOP: 'stop',
        PAUSE: 'pause',
        RESUME: 'resume',
    };

    var MenuItemType = {
        MESSAGE_CONTEXT_MENU: 'message_context_menu',
        DRAWER_MENU: 'drawer_menu',
        MAIN_MENU: 'main_menu',
        CHAT_ACTION_MENU: 'chat_action_menu',
        PROFILE_ACTION_MENU: 'profile_action_menu',
    };

    // --- HookResult -------------------------------------------------------

    function HookResult(options) {
        options = options || {};
        this.strategy = options.strategy || HookStrategy.DEFAULT;
        this.request = options.request !== undefined ? options.request : null;
        this.response = options.response !== undefined ? options.response : null;
        this.update = options.update !== undefined ? options.update : null;
        this.updates = options.updates !== undefined ? options.updates : null;
        this.params = options.params !== undefined ? options.params : null;
    }

    HookResult.cancel = function () {
        return new HookResult({ strategy: HookStrategy.CANCEL });
    };

    HookResult.modify = function (field, value) {
        var result = new HookResult({ strategy: HookStrategy.MODIFY });
        result[field] = value;
        return result;
    };

    // --- MenuItemData -----------------------------------------------------

    function MenuItemData(options) {
        options = options || {};
        this.menu_type = options.menu_type;
        this.text = options.text;
        this.on_click = options.on_click;
        this.item_id = options.item_id || null;
        this.icon = options.icon || null;
        this.subtext = options.subtext || null;
        this.condition = options.condition || null;
        this.priority = options.priority === undefined ? 0 : options.priority;
    }

    // --- ui.settings controls --------------------------------------------
    //
    // exteraGram returns dataclass instances and the host renders them. Here the
    // controls are plain objects; the Swift side reads their fields.
    //
    // Each control is a function that *returns* its object, so it works both as
    // `new Switch(...)` (what ported plugins write) and `Switch(...)`.

    function control(type, options, fields) {
        var result = { type: type };
        Object.keys(fields).forEach(function (key) {
            result[key] = fields[key];
        });
        return result;
    }

    function textOrNull(value) {
        return value === undefined || value === null ? null : value;
    }

    function callbackOrNull(value) {
        return typeof value === 'function' ? value : null;
    }

    function Header(options) {
        options = options || {};
        return control('header', options, {
            text: options.text === undefined ? '' : options.text,
        });
    }

    function Divider(options) {
        options = options || {};
        return control('divider', options, {
            text: textOrNull(options.text),
        });
    }

    function Switch(options) {
        options = options || {};
        return control('switch', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? false : options.default,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Selector(options) {
        options = options || {};
        return control('selector', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? 0 : options.default,
            items: options.items || [],
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Input(options) {
        options = options || {};
        return control('input', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? '' : options.default,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function EditText(options) {
        options = options || {};
        return control('edit_text', options, {
            key: options.key,
            hint: options.hint === undefined ? '' : options.hint,
            default: options.default === undefined ? '' : options.default,
            multiline: !!options.multiline,
            max_length: options.max_length === undefined ? 0 : options.max_length,
            mask: textOrNull(options.mask),
            on_change: callbackOrNull(options.on_change),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Text(options) {
        options = options || {};
        return control('text', options, {
            text: options.text,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            accent: !!options.accent,
            red: !!options.red,
            on_click: callbackOrNull(options.on_click),
            on_long_click: callbackOrNull(options.on_long_click),
            create_sub_fragment: callbackOrNull(options.create_sub_fragment),
            link_alias: textOrNull(options.link_alias),
            // Not in exteraGram's dataclass, where the row is identified by its
            // position. Accepting one lets a plugin keep a stable key when its
            // text is translated, and `settingKey` falls back to the text when
            // it is absent, so ported plugins are unaffected.
            key: options.key === undefined ? undefined : options.key,
        });
    }

    function Custom(options) {
        options = options || {};
        return control('custom', options, {
            item: options.item || null,
            view: options.view || null,
            factory: options.factory || null,
            factory_args: options.factory_args || [],
            on_click: callbackOrNull(options.on_click),
            on_long_click: callbackOrNull(options.on_long_click),
            create_sub_fragment: callbackOrNull(options.create_sub_fragment),
            link_alias: textOrNull(options.link_alias),
            // A factory built by `SimpleSettingFactory` carries a text preview,
            // because iOS has no Android view to draw: the renderer shows a row
            // with the factory's `text` and calls its `on_click`.
            text: options.text === undefined ? null : options.text,
            subtext: textOrNull(options.subtext),
        });
    }

    // `SimpleSettingFactory` in exteraGram builds an Android view; here it wraps
    // the pieces a row can actually render — a title line and a click handler —
    // so a ported settings list keeps its shape instead of dropping the row.
    //
    // The result is a function, not an instance, because in the SDK the factory
    // is *called* to build a setting (`Factory(link_alias="x")`,
    // `Factory("CactusPlugins", 0)`); a plain object could not be. The fields are
    // attached to that function so `new SimpleSettingFactory(...)` still works.
    function SimpleSettingFactory(createView, bindView, options) {
        options = options || {};
        var factory = function () {
            var args = Array.prototype.slice.call(arguments);
            var callOptions = {};
            if (args.length === 1 && args[0] && typeof args[0] === 'object' && !Array.isArray(args[0])) {
                callOptions = args[0];
            } else if (args.length > 0) {
                callOptions.factory_args = args;
            }
            return Custom({
                factory: factory,
                factory_args: callOptions.factory_args || [],
                on_click: factory.on_click,
                on_long_click: factory.on_long_click,
                create_sub_fragment: callOptions.create_sub_fragment || null,
                link_alias: textOrNull(callOptions.link_alias),
                text: callOptions.text === undefined ? factory.text : callOptions.text,
                subtext: callOptions.subtext === undefined ? factory.subtext : callOptions.subtext,
            });
        };
        factory.create_view = createView || null;
        factory.bind_view = bindView || null;
        factory.is_clickable = !!options.is_clickable;
        factory.is_shadow = !!options.is_shadow;
        factory.create_item = options.create_item || null;
        factory.on_click = callbackOrNull(options.on_click);
        factory.on_long_click = callbackOrNull(options.on_long_click);
        factory.attached_view = callbackOrNull(options.attached_view);
        factory.equals = callbackOrNull(options.equals);
        factory.content_equals = callbackOrNull(options.content_equals);
        factory.text = options.text === undefined ? null : options.text;
        factory.subtext = textOrNull(options.subtext);
        // `Factory.instance.java` appears in the docs; `instance` is this same
        // object and `java` is a no-op stand-in for the Java handle.
        factory.instance = factory;
        factory.java = factory;
        return factory;
    }

    // Intermediate entity form from `extera_utils.text_formatting`.
    function RawEntity(options) {
        options = options || {};
        this.offset = options.offset === undefined ? 0 : options.offset;
        this.length = options.length === undefined ? 0 : options.length;
        this.type = options.type;
        this.url = options.url;
        this.language = options.language;
        this.document_id = options.document_id;
        this.collapsed = options.collapsed;
    }

    // --- BasePlugin -------------------------------------------------------

    function BasePlugin() {
        this.log = function (message) {
            bridgeMissing('log')(pluginId, String(message));
        };

        this.getName = function () {
            return pluginName;
        };

        this.getId = function () {
            return pluginId;
        };

        this.get_setting = function (key, fallback) {
            var value = bridgeMissing('getSetting')(pluginId, key);
            if (value === null || value === undefined) {
                return fallback === undefined ? null : fallback;
            }
            return value;
        };

        this.set_setting = function (key, value, reload_settings) {
            bridgeMissing('setSetting')(pluginId, key, value, !!reload_settings);
        };

        this.export_settings = function () {
            return bridgeMissing('exportSettings')(pluginId);
        };

        this.import_settings = function (settings, reload_settings) {
            bridgeMissing('importSettings')(pluginId, settings, !!reload_settings);
        };

        this.add_hook = function (name, match_substring, priority) {
            registeredHooks.push(name);
            // exteraGram's second argument lets one registration cover a whole
            // request family (`messages.`). It has to reach the host, or a plugin
            // using it would silently never fire.
            bridgeMissing('addHook')(pluginId, name, !!match_substring);
        };

        this.add_on_send_message_hook = function () {
            sendHookEnabled = true;
            bridgeMissing('addOnSendMessageHook')(pluginId);
        };

        this.add_menu_item = function (data) {
            var itemId = data.item_id || (pluginId + '_' + Math.random().toString(36).slice(2, 10));
            var payload = {
                item_id: itemId,
                menu_type: data.menu_type,
                text: data.text,
                icon: data.icon,
                subtext: data.subtext,
                condition: data.condition,
                priority: data.priority,
                plugin_id: pluginId,
            };
            bridgeMissing('addMenuItem')(pluginId, JSON.stringify(payload));
            menuItems[itemId] = data;
            return itemId;
        };

        this.remove_menu_item = function (itemId) {
            delete menuItems[itemId];
            bridgeMissing('removeMenuItem')(pluginId, itemId);
        };

        // Message helpers: the Swift host performs the actual enqueue.
        //
        // exteraGram's signatures take the peer, the text, and keyword options
        // (`parse_mode`, `replyToMsg`, `caption`, `account`). JavaScript has no
        // keywords, so the options arrive as one trailing object; every helper
        // below accepts it in that position and nowhere else, which keeps a
        // ported call one edit away from compiling.
        this.send_text = function (peerId, text, options) {
            options = options || {};
            var payload = prepareText(text, options);
            options.entities = payload.entities;
            bridgeMissing('sendText')(
                pluginId,
                currentAccount(options.account),
                peerId,
                payload.text,
                JSON.stringify(options)
            );
        };

        this.send_photo = function (peerId, path, options) {
            options = options || {};
            options.caption = captionFor(options);
            bridgeMissing('sendFile')(pluginId, currentAccount(options.account), 'photo', peerId, path, JSON.stringify(options));
        };

        this.send_document = function (peerId, path, options) {
            options = options || {};
            options.caption = captionFor(options);
            bridgeMissing('sendFile')(pluginId, currentAccount(options.account), 'document', peerId, path, JSON.stringify(options));
        };

        this.send_video = function (peerId, path, options) {
            options = options || {};
            options.caption = captionFor(options);
            bridgeMissing('sendFile')(pluginId, currentAccount(options.account), 'video', peerId, path, JSON.stringify(options));
        };

        this.send_audio = function (peerId, path, options) {
            options = options || {};
            options.caption = captionFor(options);
            bridgeMissing('sendFile')(pluginId, currentAccount(options.account), 'audio', peerId, path, JSON.stringify(options));
        };

        // Low-level form: one object with `peer`, `message`, `path`/`document`/
        // `photo`, `caption`, `replyToMsg`, `notify`. exteraGram maps it onto
        // SendMessageParams; here it is split into the same text/file pair the
        // typed helpers use, because that is all the engine facade takes.
        // `parse_mode` applies to whichever of `message`/`caption` is present,
        // exactly as it does in the typed helpers.
        this.send_message = function (params, parseMode) {
            params = params || {};
            var options = {
                notify: params.notify,
                replyToMsg: params.replyToMsg,
                caption: params.caption,
                parse_mode: parseMode || params.parse_mode,
                account: params.account,
            };
            if (params.path || params.document || params.photo || params.video || params.audio) {
                var path = params.path || params.document || params.photo || params.video || params.audio;
                var kind = params.photo ? 'photo' : (params.video ? 'video' : (params.audio ? 'audio' : 'document'));
                options.caption = captionFor(options);
                bridgeMissing('sendFile')(
                    pluginId,
                    currentAccount(options.account),
                    kind,
                    params.peer,
                    path,
                    JSON.stringify(options)
                );
                return;
            }
            var payload = prepareText(params.message, options);
            options.entities = payload.entities;
            bridgeMissing('sendText')(
                pluginId,
                currentAccount(options.account),
                params.peer,
                payload.text,
                JSON.stringify(options)
            );
        };

        // `edit_message(message_obj, text=..., parse_mode=..., file_path=...)`.
        // The object here is a plain `{peer, id}` pair, because a ported plugin
        // cannot hold a Java MessageObject on iOS either.
        this.edit_message = function (message, text, options) {
            options = options || {};
            if (!message || message.peer === undefined || message.id === undefined) {
                throw new Error('edit_message expects {peer, id}');
            }
            var payload = prepareText(text, options);
            options.entities = payload.entities;
            bridgeMissing('editMessage')(
                pluginId,
                currentAccount(options.account || message.account),
                message.peer,
                message.id,
                payload.text,
                JSON.stringify(options)
            );
        };

        // The account a hook is running for, or null outside a callback.
        this.get_hook_account = function () {
            return hookAccount;
        };

        this.show_bulletin = function (kind, text) {
            bridgeMissing('showBulletin')(pluginId, kind, String(text));
        };

        // `self.client(account)` returns the same helpers bound to one account,
        // as `AccountClient` does in the SDK. With no argument it follows the
        // hook scope, exactly like `self.client()` there.
        this.client = function (account) {
            return makeAccountClient(currentAccount(account));
        };

        // The function stays here and the host only receives a token, because a
        // function cannot cross the bridge. `runScheduled(token)` is what the host
        // calls when the delay is over.
        //
        // The account in scope at scheduling time is captured with the callback:
        // the SDK keeps the hook's account in scope for work that hook scheduled,
        // and a callback that runs a few seconds later would otherwise have lost
        // it and quietly act on whichever account is selected.
        this.run_on_queue = function (fn, queue, delayMs) {
            if (typeof fn !== 'function') {
                throw new Error('run_on_queue expects a function');
            }
            // exteraGram's second parameter is a queue name and the third a
            // delay. Accepting the delay there as well keeps the common
            // `run_on_queue(fn, 250)` reading working.
            var delay = 0;
            if (typeof queue === 'number') {
                delay = queue;
            } else if (typeof delayMs === 'number') {
                delay = delayMs;
            }
            scheduledCounter += 1;
            var token = 'q' + scheduledCounter;
            scheduled[token] = { fn: fn, account: hookAccount };
            bridgeMissing('schedulePlugin')(pluginId, delay || 0, token);
            return token;
        };

        this.get_plugin_directory = function () {
            return bridgeMissing('pluginDirectory')(pluginId);
        };

        this.run_on_ui_thread = function (fn) {
            return this.run_on_queue(fn, 0);
        };
    }

    BasePlugin.prototype.create_settings = function () {
        return [];
    };

    // `AccountClient` from client_utils: the same helpers, bound to one account.
    // Every method maps onto the plugin-level one with `account` filled in, so
    // there is exactly one implementation of each action.
    function makeAccountClient(account) {
        var instance = function () { return __extera.instance; };
        function withAccount(options) {
            var copy = {};
            if (options && typeof options === 'object') {
                for (var key in options) {
                    if (Object.prototype.hasOwnProperty.call(options, key)) {
                        copy[key] = options[key];
                    }
                }
            }
            copy.account = account;
            return copy;
        }
        return {
            account: account,
            get_account: function () { return account; },
            send_text: function (peerId, text, options) {
                return instance().send_text(peerId, text, withAccount(options));
            },
            send_photo: function (peerId, path, options) {
                return instance().send_photo(peerId, path, withAccount(options));
            },
            send_document: function (peerId, path, options) {
                return instance().send_document(peerId, path, withAccount(options));
            },
            send_video: function (peerId, path, options) {
                return instance().send_video(peerId, path, withAccount(options));
            },
            send_audio: function (peerId, path, options) {
                return instance().send_audio(peerId, path, withAccount(options));
            },
            send_message: function (params, parseMode) {
                return instance().send_message(withAccount(params), parseMode);
            },
            edit_message: function (message, text, options) {
                return instance().edit_message(message, text, withAccount(options));
            },
        };
    }

    // Optional lifecycle hooks a plugin may override; called only when present.
    var LIFECYCLE = ['on_plugin_load', 'on_plugin_unload', 'on_app_event',
                     'pre_request_hook', 'post_request_hook',
                     'on_update_hook', 'on_updates_hook', 'on_send_message_hook'];

    function callLifecycle(instance, name, args) {
        if (instance && typeof instance[name] === 'function') {
            return instance[name].apply(instance, args || []);
        }
        return undefined;
    }

    // --- registration -----------------------------------------------------

    function register(PluginClass) {
        if (typeof PluginClass !== 'function') {
            throw new Error('plugin default export must be a class extending BasePlugin');
        }
        var instance = new PluginClass();
        __extera.instance = instance;
        return instance;
    }

    // exteraGram instantiates the module's `Plugin` class itself; a ported plugin
    // therefore does not register anything explicitly. `finalize()` supplies that
    // behaviour: it instantiates `Plugin` (or whatever `__plugin_instance__`
    // already holds) when the plugin never called `register` itself.
    function finalize() {
        if (__extera.instance) {
            return true;
        }
        var existing = typeof __plugin_instance__ !== 'undefined' ? __plugin_instance__ : null;
        if (existing && typeof existing === 'object') {
            __extera.instance = existing;
            return true;
        }
        var PluginClass = typeof Plugin !== 'undefined' ? Plugin : null;
        if (typeof PluginClass === 'function') {
            __extera.instance = new PluginClass();
            return true;
        }
        return false;
    }

    function callLifecycleJSON(event, contextJSON) {
        var instance = __extera.instance;
        if (!instance || typeof instance[event] !== 'function') {
            return null;
        }
        var extra = contextJSON ? JSON.parse(contextJSON) : {};
        // exteraGram's lifecycle signatures differ: `on_app_event(event)` takes
        // the AppEvent value, the load/unload pair takes nothing, and the rest
        // are covered by `runHook`.
        var raw;
        if (event === 'on_app_event') {
            // The host spells the event `START`; `AppEvent.START` here is
            // `'start'`, and a ported plugin compares against that constant, so
            // the value is normalized before the plugin sees it.
            var appEvent = extra.event;
            if (typeof appEvent === 'string') {
                appEvent = appEvent.toLowerCase();
            }
            raw = instance[event].call(instance, appEvent);
        } else {
            raw = instance[event].call(instance);
        }
        if (raw === undefined || raw === null) {
            return null;
        }
        if (typeof raw === 'object') {
            return JSON.stringify(raw);
        }
        return JSON.stringify({ value: raw });
    }

    // --- settings collection ---------------------------------------------
    //
    // exteraGram renders whatever `create_settings()` returns and reads each
    // control's value from the plugin's stored settings by key. The Swift
    // renderer cannot call into JS for every row, so it asks for the whole list
    // once and reads `value` from it. A control without a key gets one derived
    // from its text, which is stable across launches because the text is.

    function settingKey(control, index) {
        if (control.key !== undefined && control.key !== null && control.key !== '') {
            return String(control.key);
        }
        var basis = control.text || control.hint || control.type;
        return String(basis).toLowerCase().replace(/[^a-z0-9]+/g, '_') + '_' + index;
    }

    function collectSettings() {
        var instance = __extera.instance;
        if (!instance || typeof instance.create_settings !== 'function') {
            return '[]';
        }
        var raw = instance.create_settings();
        if (!raw || typeof raw.length !== 'number') {
            return '[]';
        }
        var result = [];
        for (var i = 0; i < raw.length; i++) {
            var control = raw[i];
            if (!control || typeof control !== 'object' || typeof control.type !== 'string') {
                continue;
            }
            var copy = {};
            for (var key in control) {
                if (Object.prototype.hasOwnProperty.call(control, key) && typeof control[key] !== 'function') {
                    copy[key] = control[key];
                }
            }
            // `link_alias` is a string, but every other callback is a function
            // and cannot cross the bridge; the host only needs to know whether
            // one exists, not what it is.
            if (control.type === 'switch' || control.type === 'selector' ||
                control.type === 'input' || control.type === 'edit_text') {
                copy.key = settingKey(control, i);
                var stored = bridgeMissing('getSetting')(pluginId, copy.key);
                copy.value = (stored === null || stored === undefined) ? control['default'] : stored;
                copy.has_callbacks = typeof control.on_change === 'function' ||
                    typeof control.on_long_click === 'function';
            }
            // `Text` and `Custom` rows are tappable in exteraGram, and a plugin
            // that only uses them for a button has no other way to be reached.
            // `has_click` tells the renderer to make the row a button rather
            // than a label; `has_sub_fragment` marks a row that opens a nested
            // settings page.
            if (control.type === 'text' || control.type === 'custom') {
                copy.key = settingKey(control, i);
                copy.has_click = typeof control.on_click === 'function';
                copy.has_long_click = typeof control.on_long_click === 'function';
                copy.has_sub_fragment = typeof control.create_sub_fragment === 'function';
            }
            result.push(copy);
        }
        return JSON.stringify(result);
    }

    // Builds a nested settings page: exteraGram's `create_sub_fragment` returns
    // another list of controls, rendered as its own screen.
    function collectSubSettings(parentKey) {
        var instance = __extera.instance;
        if (!instance || typeof instance.create_settings !== 'function') {
            return '[]';
        }
        var raw = instance.create_settings() || [];
        for (var i = 0; i < raw.length; i++) {
            var control = raw[i];
            if (!control || typeof control.create_sub_fragment !== 'function') {
                continue;
            }
            if (settingKey(control, i) !== parentKey) {
                continue;
            }
            var nested = control.create_sub_fragment() || [];
            var result = [];
            for (var j = 0; j < nested.length; j++) {
                var item = nested[j];
                if (!item || typeof item !== 'object' || typeof item.type !== 'string') {
                    continue;
                }
                var copy = {};
                for (var key in item) {
                    if (Object.prototype.hasOwnProperty.call(item, key) && typeof item[key] !== 'function') {
                        copy[key] = item[key];
                    }
                }
                if (item.type === 'switch' || item.type === 'selector' ||
                    item.type === 'input' || item.type === 'edit_text') {
                    copy.key = settingKey(item, j);
                    var stored = bridgeMissing('getSetting')(pluginId, copy.key);
                    copy.value = (stored === null || stored === undefined) ? item['default'] : stored;
                    copy.has_callbacks = typeof item.on_change === 'function';
                }
                if (item.type === 'text' || item.type === 'custom') {
                    copy.key = settingKey(item, j);
                    copy.has_click = typeof item.on_click === 'function';
                    copy.has_sub_fragment = typeof item.create_sub_fragment === 'function';
                }
                result.push(copy);
            }
            return JSON.stringify(result);
        }
        return '[]';
    }

    // --- menu items -------------------------------------------------------

    // Menu items the host should show for one menu, in exteraGram's order.
    //
    // `condition` is a function, so it cannot be evaluated when the item is
    // registered: the host asks for the list each time a menu opens, passing the
    // context exteraGram gives the callback. A condition that throws hides the
    // item rather than breaking the menu.
    function collectMenuItems(menuType, contextJSON) {
        var context = contextJSON ? JSON.parse(contextJSON) : {};
        var result = [];
        for (var itemId in menuItems) {
            if (!Object.prototype.hasOwnProperty.call(menuItems, itemId)) {
                continue;
            }
            var data = menuItems[itemId];
            if (!data || data.menu_type !== menuType || typeof data.text !== 'string') {
                continue;
            }
            if (!menuItemVisible(data, context)) {
                continue;
            }
            result.push({
                item_id: itemId,
                text: data.text,
                subtext: data.subtext === undefined ? null : data.subtext,
                icon: data.icon === undefined ? null : data.icon,
                priority: data.priority === undefined ? 0 : data.priority,
            });
        }
        result.sort(function (a, b) { return b.priority - a.priority; });
        return JSON.stringify(result);
    }

    // `MenuItemData(condition=...)` is a *string* expression in exteraGram (an
    // MVEL condition evaluated against the click context), while a JavaScript
    // port naturally writes a function. Both are accepted: a function is called
    // with the context, a string is compiled into the same kind of function.
    //
    // The compiled form sees every context key as a variable as well as the
    // whole object, so `dialog_id > 0` reads the way the MVEL version does.
    // A condition that cannot be compiled, or that throws, hides the item: a
    // menu entry whose guard is broken must not run its handler against a
    // context it did not expect.
    function menuItemVisible(data, context) {
        var condition = data.condition;
        if (condition === undefined || condition === null || condition === '') {
            return true;
        }
        if (typeof condition === 'function') {
            try {
                return !!condition(context);
            } catch (error) {
                __extera.log('menu item condition threw: ' + error);
                return false;
            }
        }
        if (typeof condition !== 'string') {
            return true;
        }
        // The names a condition may use depend on the context's keys, so the
        // compiled form is cached under both. `context` is always first, and the
        // rest keep a fixed order so the same context shape reuses one entry.
        var names = ['context'];
        for (var key in context) {
            // A key that is not a valid identifier cannot be a variable, but it
            // is still reachable as `context.key`.
            if (Object.prototype.hasOwnProperty.call(context, key) && /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key)) {
                names.push(key);
            }
        }
        var cacheKey = names.join(',') + '\n' + condition;
        var compiled = compiledConditions[cacheKey];
        if (compiled === undefined) {
            try {
                // eslint-disable-next-line no-new-func
                compiled = new Function(names.join(','), 'return (' + condition + ');');
            } catch (error) {
                __extera.log('menu item condition is not valid: ' + condition + ' (' + error + ')');
                compiled = null;
            }
            compiledConditions[cacheKey] = compiled;
        }
        if (!compiled) {
            return false;
        }
        var args = [context];
        for (var index = 1; index < names.length; index += 1) {
            args.push(context[names[index]]);
        }
        try {
            return !!compiled.apply(null, args);
        } catch (error) {
            __extera.log('menu item condition threw: ' + error);
            return false;
        }
    }

    // Runs a menu item's click handler. The context is what the host knows about
    // the place the menu was opened from; the callback receives it as an object.
    function runMenuItem(itemId, contextJSON) {
        var data = menuItems[itemId];
        if (!data || typeof data.on_click !== 'function') {
            return;
        }
        data.on_click(contextJSON ? JSON.parse(contextJSON) : {});
    }

    // Calls a control callback by key, used when the user edits a setting. The
    // function object never crosses the bridge; the key does. `valueJSON` is the
    // new value, encoded so it can arrive through a string-only bridge.
    function invokeSettingCallback(key, kind, valueJSON) {
        var instance = __extera.instance;
        if (!instance || typeof instance.create_settings !== 'function') {
            return;
        }
        var value = valueJSON ? JSON.parse(valueJSON) : null;
        if (value !== null && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'value')) {
            value = value.value;
        }
        var raw = instance.create_settings() || [];
        for (var i = 0; i < raw.length; i++) {
            var control = raw[i];
            if (!control) {
                continue;
            }
            if (settingKey(control, i) !== key) {
                continue;
            }
            var fn;
            switch (kind) {
            case 'click':
                fn = control.on_click;
                break;
            case 'long_click':
                fn = control.on_long_click;
                break;
            default:
                fn = control.on_change;
                break;
            }
            if (typeof fn === 'function') {
                // exteraGram passes the clicked Android `View` to `on_click`.
                // There is no view here, so the row's key is the argument: a
                // plugin that only logs or runs its own logic is unaffected.
                if (kind === 'click' || kind === 'long_click') {
                    fn.call(instance, { key: key, getKey: function () { return key; } });
                } else {
                    fn.call(instance, value === undefined ? null : value);
                }
            }
            return;
        }
    }

    // Runs a callback that `run_on_queue` registered. The host holds only the
    // token, so this is the only way the function can be reached again.
    function runScheduled(token) {
        var entry = scheduled[token];
        if (!entry || typeof entry.fn !== 'function') {
            return;
        }
        delete scheduled[token];
        // Re-enter the account scope the callback was scheduled in, so a reply
        // it sends goes out from the account whose hook asked for it.
        withHookAccount(entry.account, entry.fn);
    }

    function normalizeResult(value, field) {
        if (value === null || value === undefined) {
            return { strategy: HookStrategy.DEFAULT, value: null };
        }
        if (typeof value !== 'object') {
            return { strategy: HookStrategy.DEFAULT, value: null };
        }
        var strategy = value.strategy || HookStrategy.DEFAULT;
        var payload = value[field];
        if (payload === null || payload === undefined) {
            payload = null;
        }
        return { strategy: strategy, value: payload };
    }

    // --- hook invocation --------------------------------------------------
    //
    // Swift passes a JSON-encoded event and gets back a JSON-encoded result.
    // Running the call here, rather than calling the method straight from
    // Swift, keeps `this` bound to the plugin instance and keeps every JS
    // object on the JS side: the only things crossing the bridge are strings.
    // `runHook` returns:
    //   { "strategy": "default" }                      nothing asked for
    //   { "strategy": "cancel" }                       request suppressed
    //   { "strategy": "modify", "payload": {...} }     replacement payload
    //   { "result": <JSON string> }                    for notify-type hooks

    function runHook(event, payloadJSON, contextJSON) {
        var instance = __extera.instance;
        if (!instance) {
            return JSON.stringify({ strategy: HookStrategy.DEFAULT });
        }
        var fn = instance[event];
        if (typeof fn !== 'function') {
            return JSON.stringify({ strategy: HookStrategy.DEFAULT });
        }
        var payload = payloadJSON ? JSON.parse(payloadJSON) : null;
        var extra = contextJSON ? JSON.parse(contextJSON) : {};

        // exteraGram names hooks by TL constructor (`TL_messages_setTyping`).
        // The host registers and matches them in the dotted form and sends both
        // spellings, so a callback compares against whichever it was written for.
        var hookName = extra.tlName || extra.name;

        var raw;
        // The callback runs inside the account scope of the hook, so
        // `get_hook_account()` and a bare `self.client()` see the account it
        // fired for rather than the one selected in the UI.
        raw = withHookAccount(extra.account, function () {
            switch (event) {
            case 'pre_request_hook':
                return fn.call(instance, hookName, extra.account, payload);
            case 'post_request_hook':
                return fn.call(instance, hookName, extra.account, payload, extra.error === undefined ? null : extra.error);
            case 'on_send_message_hook':
                return fn.call(instance, extra.account, payload);
            case 'on_update_hook':
                return fn.call(instance, hookName, extra.account, payload);
            case 'on_updates_hook':
                // A batch crosses the bridge as `{"updates": [...]}`, because only a
                // dictionary fits the host's payload type. exteraGram hands the hook
                // the list itself, so unwrap it here.
                return fn.call(instance, hookName, extra.account, (payload && payload.updates) || []);
            default:
                return fn.call(instance, payload, extra);
            }
        });

        var result = normalizeResult(raw, extra.field || 'request');
        var out = { strategy: result.strategy };
        if (result.value !== null && typeof result.value === 'object') {
            out.payload = result.value;
        }
        return JSON.stringify(out);
    }

    return {
        setIdentity: function (id, name) {
            pluginId = id;
            pluginName = name;
        },
        name: function () { return pluginName; },
        id: function () { return pluginId; },
        bulletin: function (kind, text) {
            bridgeMissing('showBulletin')(pluginId, kind, String(text));
        },
        // Richer bulletin: a title line, a button, an undo action, or one of the
        // canned "copied"/"saved" variants. `json` is already shaped by
        // `ui.bulletin`; callbacks inside it are tokens.
        bulletinJson: function (object) {
            bridgeMissing('showBulletin')(pluginId, object.kind || 'info', JSON.stringify(object));
        },
        holdCallback: holdCallback,
        runCallback: runCallback,
        parseText: parseText,
        // A `file_utils` call. The host answers with a JSON document, so the
        // value arrives with its real type (`true`, `null`, `["a"]`) instead of
        // as a string the plugin would have to parse itself.
        fileValue: function (op, path, payload) {
            var json = bridgeMissing('fileOp')(pluginId, op, path, payload);
            if (json === undefined || json === null) {
                return null;
            }
            try {
                return JSON.parse(json);
            } catch (error) {
                return null;
            }
        },
        selectedAccount: function () {
            // Resolved once per call so the value follows an account switch
            // without the plugin subscribing to anything.
            if (hasBridge('selectedAccount')) {
                var value = host().selectedAccount(pluginId);
                if (typeof value === 'number' && isFinite(value)) {
                    selectedAccount = value;
                }
            }
            return selectedAccount;
        },
        copyToClipboard: function (text) {
            if (hasBridge('copyToClipboard')) {
                host().copyToClipboard(pluginId, String(text));
            }
        },
        setSelectedAccount: function (account) { selectedAccount = account; },
        hookAccount: function () { return hookAccount; },
        resolveAccount: currentAccount,
        TLEntityType: TLEntityType,
        // The plugin-visible `__extera.api` object is `ui.settings`; the
        // encryption of a control key into a stable id lives with it.
        settingKey: settingKey,
        makeAccountClient: makeAccountClient,
        log: function (message) {
            bridgeMissing('log')(pluginId, String(message));
        },
        instance: null,
        register: register,
        finalize: finalize,
        callLifecycle: callLifecycle,
        callLifecycleJSON: callLifecycleJSON,
        normalizeResult: normalizeResult,
        runHook: runHook,
        runScheduled: runScheduled,
        collectSettings: collectSettings,
        collectSubSettings: collectSubSettings,
        collectMenuItems: collectMenuItems,
        runMenuItem: runMenuItem,
        invokeSettingCallback: invokeSettingCallback,
        LIFECYCLE: LIFECYCLE,
        api: {
            BasePlugin: BasePlugin,
            HookResult: HookResult,
            HookStrategy: HookStrategy,
            MenuItemData: MenuItemData,
            MenuItemType: MenuItemType,
            AppEvent: AppEvent,
            Header: Header,
            Divider: Divider,
            Switch: Switch,
            Selector: Selector,
            Input: Input,
            EditText: EditText,
            Text: Text,
            Custom: Custom,
            SimpleSettingFactory: SimpleSettingFactory,
            AlertDialogBuilder: AlertDialogBuilder,
            TLEntityType: TLEntityType,
            RawEntity: RawEntity,
            parse_text: parseText,
        },
    };
})();

// The names plugins import in exteraGram are module-scope there. Expose the same
// names as globals so a plugin body compiles unchanged apart from its import lines.
var BasePlugin = __extera.api.BasePlugin;
var HookResult = __extera.api.HookResult;
var HookStrategy = __extera.api.HookStrategy;
var MenuItemData = __extera.api.MenuItemData;
var MenuItemType = __extera.api.MenuItemType;
var AppEvent = __extera.api.AppEvent;

var Header = __extera.api.Header;
var Divider = __extera.api.Divider;
var Switch = __extera.api.Switch;
var Selector = __extera.api.Selector;
var Input = __extera.api.Input;
var EditText = __extera.api.EditText;
var Text = __extera.api.Text;
var Custom = __extera.api.Custom;

// `ui.settings`, `client_utils`, `hook_utils` and `android_utils` are Python
// modules in exteraGram. Here they are plain objects so a ported plugin can keep
// its shape: `var settings = ui.settings; settings.Switch(...)`.
var ui = {
    settings: __extera.api,
    // `BulletinHelper` is a class of static methods in the SDK. Exposing it on the
    // module object means `ui.bulletin.show_info(...)` and
    // `ui.bulletin.BulletinHelper.show_info(...)` both work, which is how a
    // ported `from ui.bulletin import BulletinHelper` reads after its import
    // line is dropped.
    bulletin: {
        DURATION_SHORT: 1500,
        DURATION_LONG: 2750,
        DURATION_PROLONG: 5000,
        show_info: function (text) {
            __extera.bulletinJson({ kind: 'info', text: String(text) });
        },
        show_error: function (text) {
            __extera.bulletinJson({ kind: 'error', text: String(text) });
        },
        show_success: function (text) {
            __extera.bulletinJson({ kind: 'success', text: String(text) });
        },
        show_simple: function (text) {
            __extera.bulletinJson({ kind: 'info', text: String(text) });
        },
        show_two_line: function (title, text) {
            __extera.bulletinJson({ kind: 'info', title: String(title), text: String(text) });
        },
        show_with_button: function (text, icon, buttonText, onAction, fragment, duration) {
            // A button needs a callback, which cannot cross the bridge: it is
            // stored under a token and the host calls back into
            // `runBulletinAction(token)`.
            var token = null;
            if (typeof onAction === 'function') {
                token = __extera.holdCallback(onAction);
            }
            __extera.bulletinJson({
                kind: 'button',
                text: String(text),
                icon: icon === undefined || icon === null ? null : String(icon),
                button: buttonText === undefined || buttonText === null ? null : String(buttonText),
                token: token,
                duration: typeof duration === 'number' ? duration : null,
            });
        },
        show_undo: function (text, options) {
            options = options || {};
            var undoToken = typeof options.on_undo === 'function' ? __extera.holdCallback(options.on_undo) : null;
            var actionToken = typeof options.on_action === 'function' ? __extera.holdCallback(options.on_action) : null;
            __extera.bulletinJson({
                kind: 'undo',
                text: String(text),
                undo_text: options.undo_text === undefined ? null : String(options.undo_text),
                undo_token: undoToken,
                action_token: actionToken,
                destructive: !!options.destructive,
            });
        },
        show_copied_to_clipboard: function (message) {
            __extera.bulletinJson({ kind: 'copied', text: message === undefined ? null : String(message) });
        },
        show_link_copied: function () {
            __extera.bulletinJson({ kind: 'link_copied', text: null });
        },
        show_file_saved_to_gallery: function (isVideo, amount) {
            __extera.bulletinJson({
                kind: 'saved_gallery',
                video: !!isVideo,
                amount: typeof amount === 'number' ? amount : 1,
            });
        },
        show_file_saved_to_downloads: function (fileType, amount) {
            __extera.bulletinJson({
                kind: 'saved_downloads',
                file_type: fileType === undefined ? null : String(fileType),
                amount: typeof amount === 'number' ? amount : 1,
            });
        },
    },
    // `BulletinHelper` in the SDK is a class whose methods are called statically, and
    // the module also exposes them directly. The same functions answer to both
    // names, so dropping `from ui.bulletin import BulletinHelper` leaves a plugin
    // that still runs. Assigning after the literal is what keeps one copy of each
    // function instead of a second table to keep in sync.
    alert: {
        // `AlertDialogBuilder(activity, type)` — the activity argument is what
        // Android needs to attach a window; iOS presents from the current screen,
        // so the constructor ignores it and keeps the same shape.
        AlertDialogBuilder: __extera.api.AlertDialogBuilder,
    },
};

// `ui.bulletin` is a module that also exports `BulletinHelper`, a class of static
// methods. Both spellings point at the same functions: a port drops its import
// line either way and keeps working.
ui.bulletin.BulletinHelper = ui.bulletin;

var android_utils = {
    log: function (message) { __extera.log(message); },

    // Everything below exists on Android to hand a `Runnable`/listener object to
    // Java. There is no Java here, so the wrappers return the callable itself:
    // it can still be called, and code that only passes it around does not break.
    R: function (fn) { return fn; },
    OnClickListener: function (fn) { return fn; },
    OnLongClickListener: function (fn) { return fn; },

    // The host runs script-queue work in order and every action it performs ends
    // up on the main queue, so "on the UI thread" is the same scheduling.
    run_on_ui_thread: function (fn, delayMs) {
        return __extera.instance.run_on_queue(fn, 0, typeof delayMs === 'number' ? delayMs : 0);
    },

    copy_to_clipboard: function (text) {
        return __extera.copyToClipboard(text === undefined || text === null ? '' : String(text));
    },
};

var hook_utils = {
    // iOS has no Objective-C reflection surface exposed to plugins; these return
    // null rather than pretending to work, so a ported plugin degrades instead of
    // failing at load time.
    find_class: function () { return null; },
    get_private_field: function () { return null; },
    set_private_field: function () { return false; },
    get_static_private_field: function () { return null; },
    set_static_private_field: function () { return false; },
};

// --- client_utils --------------------------------------------------------
//
// The module-level half of the same helpers the plugin class gets. Everything
// that needs an account resolves it through `currentAccount`, so these calls
// behave the same inside a hook as `self.client()`. Helpers that need a real
// Android controller (`get_messages_controller` and friends) return null and
// log once: pretending they work would be worse than a plugin that guards the
// result, which is what exteraGram's own examples do anyway.
var client_utils = {
    // Queue names from the SDK. There is one script queue on iOS, so the names
    // are accepted and ignored: `run_on_queue` serializes either way, and a
    // plugin that reads the constant to pass it back keeps working.
    STAGE_QUEUE: 'stageQueue',
    GLOBAL_QUEUE: 'globalQueue',
    CACHE_CLEAR_QUEUE: 'cacheClearQueue',
    SEARCH_QUEUE: 'searchQueue',
    PHONE_BOOK_QUEUE: 'phoneBookQueue',
    THEME_QUEUE: 'themeQueue',
    EXTERNAL_NETWORK_QUEUE: 'externalNetworkQueue',
    PLUGINS_QUEUE: 'pluginsQueue',
    run_on_queue: function (fn, queue, delayMs) {
        return __extera.instance.run_on_queue(fn, queue, delayMs);
    },
    run_on_ui_thread: function (fn) {
        return __extera.instance.run_on_ui_thread(fn);
    },
    get_hook_account: function () {
        return __extera.hookAccount();
    },
    get_selected_account: function () {
        return __extera.selectedAccount();
    },
    get_client: function (account) {
        return __extera.makeAccountClient(currentAccount(account));
    },
    send_text: function (peerId, text, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.send_text(peerId, text, options);
    },
    send_photo: function (peerId, path, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.send_photo(peerId, path, options);
    },
    send_document: function (peerId, path, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.send_document(peerId, path, options);
    },
    send_video: function (peerId, path, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.send_video(peerId, path, options);
    },
    send_audio: function (peerId, path, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.send_audio(peerId, path, options);
    },
    send_message: function (params, parseMode) {
        params = params || {};
        params.account = currentAccount(params.account);
        return __extera.instance.send_message(params, parseMode);
    },
    edit_message: function (message, text, options) {
        options = options || {};
        options.account = currentAccount(options.account);
        return __extera.instance.edit_message(message, text, options);
    },
    parse_text: function (text, parseMode, isCaption) {
        return __extera.parseText(text, parseMode, isCaption);
    },
};

// The controller getters exist so a ported import line still resolves. Needing
// one means the plugin wanted to reach into Telegram's own UI objects, which is
// the layer this runtime deliberately keeps closed; returning null makes a
// plugin's own `if not controller: return` guard take the safe branch.
['get_last_fragment', 'get_account_instance', 'get_messages_controller',
 'get_contacts_controller', 'get_media_data_controller',
 'get_connections_manager', 'get_location_controller',
 'get_notifications_controller', 'get_messages_storage',
 'get_send_messages_helper', 'get_file_loader', 'get_secret_chat_helper',
 'get_download_controller', 'get_notifications_settings',
 'get_notification_center', 'get_media_controller', 'get_user_config',
 'get_queue_by_name', 'send_request'].forEach(function (name) {
    client_utils[name] = function () {
        __extera.log(name + ' is not available on iOS; returning null');
        return null;
    };
});

// `NotificationCenterDelegate` is an Android observer base class. A plugin that
// subclasses it still loads and instantiates; observing anything is what has no
// equivalent, so `get_notification_center()` above returns null and a guard in
// the plugin takes its safe branch.
function NotificationCenterDelegate() {
}
client_utils.NotificationCenterDelegate = NotificationCenterDelegate;

// --- file_utils ----------------------------------------------------------
//
// Directories follow iOS: the plugin's own folder, and the app's Documents and
// caches. Everything goes through the host, so a plugin can only touch files
// inside those roots and the encoding rules stay in one place.

var file_utils = {
    get_plugins_dir: function () {
        return __extera.instance.get_plugin_directory();
    },
    get_cache_dir: function () {
        return __extera.fileValue('cache_dir', '', null);
    },
    get_files_dir: function () {
        return __extera.fileValue('files_dir', '', null);
    },
    get_images_dir: function () {
        return __extera.fileValue('images_dir', '', null);
    },
    get_videos_dir: function () {
        return __extera.fileValue('videos_dir', '', null);
    },
    get_audios_dir: function () {
        return __extera.fileValue('audios_dir', '', null);
    },
    get_documents_dir: function () {
        return __extera.fileValue('documents_dir', '', null);
    },
    ensure_dir_exists: function (path) {
        return __extera.fileValue('ensure_dir', path, null);
    },
    read_file: function (path) {
        return __extera.fileValue('read_text', path, null);
    },
    write_file: function (path, contents) {
        return __extera.fileValue('write_text', path, contents === undefined ? '' : String(contents));
    },
    read_file_bytes: function (path) {
        // A byte array cannot cross a string-only bridge, so this returns the
        // base64 text and the docstring says so. `bytes(...)` on it is not
        // possible, which is why the base64 form is the documented one here.
        return __extera.fileValue('read_bytes', path, null);
    },
    write_file_bytes: function (path, contentsBase64) {
        return __extera.fileValue('write_bytes', path, contentsBase64 === undefined ? '' : String(contentsBase64));
    },
    list_dir: function (path, recursiveOrOptions, includeFiles, includeDirs, extensions) {
        // exteraGram's signature is `list_dir(path, recursive=False,
        // include_files=True, include_dirs=False, extensions=None)`. JS has no
        // keywords, so the flags arrive positionally; a single object is accepted
        // too, because that reads naturally in a port.
        var options = {};
        if (recursiveOrOptions && typeof recursiveOrOptions === 'object' && !Array.isArray(recursiveOrOptions)) {
            options = recursiveOrOptions;
        } else {
            if (recursiveOrOptions !== undefined && recursiveOrOptions !== null) {
                options.recursive = !!recursiveOrOptions;
            }
            if (includeFiles !== undefined && includeFiles !== null) {
                options.include_files = !!includeFiles;
            }
            if (includeDirs !== undefined && includeDirs !== null) {
                options.include_dirs = !!includeDirs;
            }
            if (extensions !== undefined && extensions !== null) {
                options.extensions = extensions;
            }
        }
        var value = __extera.fileValue('list_dir', path, JSON.stringify(options));
        return Array.isArray(value) ? value : [];
    },
    delete_file: function (path) {
        return __extera.fileValue('delete', path, null);
    },
    file_exists: function (path) {
        return __extera.fileValue('exists', path, null);
    },
};

// `file_utils.FilesController` intercepts the app's own "open this file" flow.
// iOS has no such hook, and a plugin registering a handler would never be called,
// so the object keeps the shape (the enum values and file names a port references)
// while `register` returns a token and logs that nothing will fire. `SUPPORT_ICONS`
// is false, which is the SDK's own signal for "do not pass get_icon".
file_utils.FilesController = {
    SUPPORT_ICONS: false,
    Place: {
        UNKNOWN: 'UNKNOWN',
        ChatActivity: 'ChatActivity',
        FilteredSearchView: 'FilteredSearchView',
        SharedMediaLayout: 'SharedMediaLayout',
        SearchDownloadsContainer: 'SearchDownloadsContainer',
        ChannelAdminLogActivity: 'ChannelAdminLogActivity',
    },
    FileInfo: function (options) {
        options = options || {};
        this.ext = options.ext;
        this.on_click = options.on_click || null;
        this.whitelist_places = options.whitelist_places || [];
        this.blacklist_places = options.blacklist_places || [];
        this.get_icon = options.get_icon || null;
    },
    OnClickArgs: function (options) {
        options = options || {};
        this.place = options.place;
        this.file = options.file;
        this.file_name = options.file_name;
        this.message = options.message;
        this.activity = options.activity;
        this.parent_fragment = options.parent_fragment;
    },
    ExtensionAlreadyRegistered: function (message) {
        this.name = 'ExtensionAlreadyRegistered';
        this.message = message || 'extension already registered';
    },
    ExtensionNotRegistered: function (message) {
        this.name = 'ExtensionNotRegistered';
        this.message = message || 'extension not registered';
    },
    SecretInvalid: function (message) {
        this.name = 'SecretInvalid';
        this.message = message || 'invalid secret';
    },
    _registered: {},
    register: function (info) {
        var ext = info && info.ext ? String(info.ext).toLowerCase().replace(/^\./, '') : '';
        if (!ext) {
            throw new file_utils.FilesController.SecretInvalid('a file extension is required');
        }
        if (this._registered[ext]) {
            throw new file_utils.FilesController.ExtensionAlreadyRegistered(ext);
        }
        var secret = 'files-' + ext + '-' + Math.random().toString(36).slice(2, 10);
        this._registered[ext] = secret;
        __extera.log('FilesController cannot intercept file opening on iOS; ".' + ext + '" was not registered');
        return secret;
    },
    unregister: function (ext, secret) {
        var key = String(ext || '').toLowerCase().replace(/^\./, '');
        if (!this._registered[key]) {
            throw new file_utils.FilesController.ExtensionNotRegistered(key);
        }
        if (this._registered[key] !== secret) {
            throw new file_utils.FilesController.SecretInvalid();
        }
        delete this._registered[key];
    },
};

// --- intents -------------------------------------------------------------
//
// Android intents have no iOS equivalent. The object exists so an import line
// resolves, and every call logs instead of throwing.
var intents = {
    Intent: function () { return {}; },
    IntentsManager: {
        send: function () {
            __extera.log('intents are not available on iOS');
            return false;
        },
        startActivity: function () {
            __extera.log('intents are not available on iOS');
            return false;
        },
    },
};

// --- extera_utils ---------------------------------------------------------
//
// The SDK's `extera_utils` package has two modules a plugin imports from:
// `text_formatting` (implemented above in full) and `classes` (Java subclassing
// through DexMaker). The class-proxy half cannot exist without Java, so its
// decorators are identity functions and `java_subclass` returns a constructor
// that refuses cleanly. A plugin that only *defines* such a class still loads;
// one that tries to instantiate it gets a clear error instead of a crash.

function unsupportedClass(name) {
    return function () {
        throw new Error(name + ' needs runtime Java subclassing, which does not exist on iOS');
    };
}

var extera_utils = {
    text_formatting: {
        parse_text: function (text, parseMode, isCaption) {
            return __extera.parseText(text, parseMode, isCaption);
        },
        TLEntityType: __extera.TLEntityType,
        RawEntity: function (options) {
            options = options || {};
            this.offset = options.offset || 0;
            this.length = options.length || 0;
            this.type = options.type;
            this.url = options.url;
            this.language = options.language;
            this.document_id = options.document_id;
            this.collapsed = options.collapsed;
        },
    },
    classes: {
        // Decorators record the intent and return the function/decorated member
        // unchanged; nothing can be generated without a Java runtime.
        Base: function () {},
        java_subclass: function (clazz) {
            return function (target) {
                target.__java_superclass__ = clazz;
                return target;
            };
        },
        joverride: function () { return function (target) { return target; }; },
        joverload: function () { return function (target) { return target; }; },
        jmethod: function () { return function (target) { return target; }; },
        jfield: function (type, defaultValue) { return defaultValue; },
        jconstructor: function () { return function (target) { return target; }; },
        jpreconstructor: function () { return function (target) { return target; }; },
        jMVELmethod: function () { return function (target) { return target; }; },
        jMVELoverride: function () { return function (target) { return target; }; },
        jclassbuilder: function () { return unsupportedClass('jclassbuilder'); },
        jgetmethod: function (name) {
            return function (self) { return self ? self[name] : undefined; };
        },
        jsetmethod: function (name) {
            return function (self, value) { if (self) { self[name] = value; } };
        },
    },
};