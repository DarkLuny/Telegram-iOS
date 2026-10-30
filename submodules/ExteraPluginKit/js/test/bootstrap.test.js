/*
 * Runs bootstrap.js the way the app does, with a fake `__host`, and checks the
 * API a ported plugin relies on. `node js/test/bootstrap.test.js`.
 *
 * The Swift host implements the same member list; when one side gains a bridge,
 * the other must follow, so this file is the contract check.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const bootstrap = fs.readFileSync(path.join(__dirname, '..', 'bootstrap.js'), 'utf8');

function makeHost() {
    const calls = [];
    const settings = {};
    const host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: (id, key) => (key in settings ? settings[key] : null),
        setSetting: (id, key, value) => { settings[key] = value; calls.push(['setSetting', id, key, value]); },
        exportSettings: () => ({ ...settings }),
        importSettings: (id, values) => { Object.assign(settings, values); calls.push(['importSettings', id]); },
        addHook: (id, name, matchSubstring) => calls.push(['addHook', id, name, !!matchSubstring]),
        addOnSendMessageHook: (id) => calls.push(['addOnSendMessageHook', id]),
        addMenuItem: (id, json) => { calls.push(['addMenuItem', id, JSON.parse(json)]); return 'item'; },
        removeMenuItem: (id, itemId) => calls.push(['removeMenuItem', id, itemId]),
        sendText: (id, account, peerId, text, opts) => calls.push(['sendText', id, account, peerId, text, JSON.parse(opts || '{}')]),
        sendFile: (id, account, kind, peerId, p, opts) => calls.push(['sendFile', id, account, kind, peerId, p, JSON.parse(opts || '{}')]),
        editMessage: (id, account, peerId, msgId, text, opts) => calls.push(['editMessage', id, account, peerId, msgId, text, JSON.parse(opts || '{}')]),
        showBulletin: (id, kind, text) => calls.push(['showBulletin', id, kind, text]),
        showAlert: (id, json) => calls.push(['showAlert', id, JSON.parse(json)]),
        dismissAlert: (id) => calls.push(['dismissAlert', id]),
        fileOp: (id, op, p, payload) => {
            calls.push(['fileOp', id, op, p, payload]);
            return (host.fileResults && op in host.fileResults) ? JSON.stringify(host.fileResults[op]) : JSON.stringify(null);
        },
        selectedAccount: () => 42,
        pluginDirectory: () => '/plugins/demo',
        schedulePlugin: (id, delay, token) => calls.push(['schedulePlugin', id, delay, token]),
    };
    return host;
}

function runPlugin(source, host) {
    const context = vm.createContext({ __host: host, console });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext('__extera.setIdentity("demo", "Demo")', context);
    vm.runInContext(source, context, { filename: 'demo.plugin.js' });
    return context;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata and lifecycle are exposed to the host', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __id__ = "demo";
        var __name__ = "Demo";
        var loaded = false;
        class P extends BasePlugin {
            on_plugin_load() { loaded = true; this.log("hi"); }
        }
        var __plugin_instance__ = __extera.register(P);
        __extera.callLifecycle(__plugin_instance__, "on_plugin_load", []);
    `, host);
    assert.strictEqual(ctx.loaded, true);
    assert.ok(host.calls.some(c => c[0] === 'log' && c[2] === 'hi'));
});

test('send hook receives params object and can modify it', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_send_message_hook(account, params) {
                if (params.message.startsWith(".hello")) {
                    params.message = params.message.replace(".hello", "Hello from plugin");
                    var r = new HookResult();
                    r.strategy = HookStrategy.MODIFY;
                    r.params = params;
                    return r;
                }
                return new HookResult();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const instance = ctx.__extera.instance;
    const params = { message: '.hello world' };
    const raw = instance.on_send_message_hook(0, params);
    const normalized = ctx.__extera.normalizeResult(raw, 'params');
    assert.strictEqual(normalized.strategy, 'modify');
    assert.strictEqual(normalized.value.message, 'Hello from plugin world');
});

test('pre_request_hook can cancel', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            pre_request_hook(name, account, request) {
                if (name === "TL_messages_setTyping") {
                    return HookResult.cancel();
                }
                return new HookResult();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const r = ctx.__extera.instance.pre_request_hook('TL_messages_setTyping', 0, {});
    assert.strictEqual(ctx.__extera.normalizeResult(r, 'request').strategy, 'cancel');
});

test('add_hook forwards match_substring to the host', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_plugin_load() {
                this.add_hook('messages.', true);
                this.add_hook('messages.sendMessage');
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    ctx.__extera.callLifecycle(ctx.__extera.instance, 'on_plugin_load', []);
    const substring = host.calls.find(c => c[0] === 'addHook' && c[2] === 'messages.');
    const exact = host.calls.find(c => c[0] === 'addHook' && c[2] === 'messages.sendMessage');
    assert.strictEqual(substring[3], true);
    assert.strictEqual(exact[3], false);
});

test('settings controls keep every field the renderer reads', () => {    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            create_settings() {
                return [
                    new Header({ text: "General" }),
                    new Switch({ key: "enabled", text: "Enable feature", default: true, subtext: "Sample" }),
                    new Selector({ key: "mode", text: "Mode", default: 1, items: ["Off", "Basic", "Advanced"] }),
                    new Input({ key: "name", text: "Name", default: "Alice" }),
                    new EditText({ key: "bio", hint: "Bio", multiline: true, max_length: 200 }),
                    new Text({ text: "Warning", red: true }),
                    new Divider({ text: "Section" }),
                ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const items = ctx.__extera.instance.create_settings();
    // Arrays cross the vm realm boundary, so compare as plain values.
    assert.strictEqual(JSON.stringify(items.map(i => i.type)),
        JSON.stringify(['header', 'switch', 'selector', 'input', 'edit_text', 'text', 'divider']));
    assert.strictEqual(items[1].key, 'enabled');
    assert.strictEqual(items[1].default, true);
    assert.strictEqual(JSON.stringify(items[2].items), JSON.stringify(['Off', 'Basic', 'Advanced']));
    assert.strictEqual(items[4].multiline, true);
    assert.strictEqual(items[5].red, true);
});

test('menu items reach the host with a stable id', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_plugin_load() {
                this.item = this.add_menu_item(new MenuItemData({
                    menu_type: MenuItemType.MESSAGE_CONTEXT_MENU,
                    text: "Log Message Info",
                    icon: "msg_info",
                    priority: 10,
                    on_click: function (ctx) {},
                }));
            }
        }
        var __plugin_instance__ = __extera.register(P);
        __extera.callLifecycle(__plugin_instance__, "on_plugin_load", []);
    `, host);
    const added = host.calls.find(c => c[0] === 'addMenuItem');
    assert.ok(added, 'menu item was not registered');
    assert.strictEqual(added[2].menu_type, 'message_context_menu');
    assert.strictEqual(added[2].priority, 10);
    assert.ok(added[2].item_id.startsWith('demo_'));
});

test('settings round-trip through the host', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {}
        var __plugin_instance__ = __extera.register(P);
        __plugin_instance__.set_setting("enabled", false);
        var read = __plugin_instance__.get_setting("enabled", true);
        var missing = __plugin_instance__.get_setting("nope", "fallback");
    `, host);
    assert.strictEqual(ctx.read, false);
    assert.strictEqual(ctx.missing, 'fallback');
});

test('ported plugin keeps exteraGram shape via ui.settings aliases', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var settings = ui.settings;
        class P extends BasePlugin {
            create_settings() {
                return [ settings.Switch({ key: "a", text: "A", default: true }) ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    assert.strictEqual(ctx.__extera.instance.create_settings()[0].type, 'switch');
});

test('finalize() instantiates a plugin that never registers itself', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() { this.log("loaded via finalize"); }
        }
    `, host);
    assert.strictEqual(ctx.__extera.instance, null);
    assert.strictEqual(ctx.__extera.finalize(), true);
    assert.ok(ctx.__extera.instance);
});

test('runHook keeps `this` bound and returns a JSON decision', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.state = "ready";
            }
            pre_request_hook(name, account, request) {
                if (name === "TL_messages_sendMessage") {
                    request.text = this.state + ": " + request.text;
                    var r = new HookResult();
                    r.strategy = HookStrategy.MODIFY;
                    r.request = request;
                    return r;
                }
                return new HookResult();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'TL_messages_sendMessage', account: 7, field: 'request' });
    const out = JSON.parse(ctx.__extera.runHook('pre_request_hook', JSON.stringify({ text: 'hi' }), context));
    assert.strictEqual(out.strategy, 'modify');
    assert.strictEqual(out.payload.text, 'ready: hi');
});

test('runHook reports cancellation for a send hook', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            pre_request_hook(name, account, request) {
                return HookResult.cancel();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const out = JSON.parse(ctx.__extera.runHook('pre_request_hook', '{}', JSON.stringify({ name: 'x', account: 0 })));
    assert.strictEqual(out.strategy, 'cancel');
});

test('collectSettings resolves stored values and stable keys', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            create_settings() {
                return [
                    new Header({ text: "General" }),
                    new Switch({ text: "No Key", default: true }),
                    new Selector({ key: "mode", text: "Mode", default: 0, items: ["a","b"] }),
                ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
        __plugin_instance__.set_setting("mode", 1);
    `, host);
    const items = JSON.parse(ctx.__extera.collectSettings());
    assert.strictEqual(items.length, 3);
    assert.strictEqual(items[1].key, 'no_key_1');
    assert.strictEqual(items[1].value, true);
    assert.strictEqual(items[2].value, 1);
    assert.strictEqual(items[0].value, undefined);
});

test('invokeSettingCallback reaches the callback without passing functions', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.seen = null;
            }
            create_settings() {
                var self = this;
                return [ new Switch({ key: "on", text: "On", default: false, on_change: function (value) { self.seen = value; } }) ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    ctx.__extera.invokeSettingCallback('on', 'change', JSON.stringify({ value: true }));
    assert.strictEqual(ctx.__extera.instance.seen, true);
});

test('callLifecycleJSON passes the AppEvent value', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_app_event(event) { this.lastEvent = event; return { handled: true }; }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    // The host sends "RESUME"; the plugin compares against AppEvent.RESUME.
    const out = JSON.parse(ctx.__extera.callLifecycleJSON('on_app_event', JSON.stringify({ event: 'RESUME' })));
    assert.strictEqual(ctx.__extera.instance.lastEvent, 'resume');
    assert.strictEqual(out.handled, true);
});

test('every host app event matches the AppEvent constant a plugin compares with', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_app_event(event) { this.seen = (this.seen || []).concat([event]); }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    for (const name of ['START', 'STOP', 'PAUSE', 'RESUME']) {
        ctx.__extera.callLifecycleJSON('on_app_event', JSON.stringify({ event: name }));
        assert.strictEqual(ctx.__extera.instance.seen.slice(-1)[0], ctx['AppEvent'][name]);
    }
});

test('run_on_queue hands the host a token and runScheduled fires it once', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.fired = 0;
            }
        }
        var __plugin_instance__ = __extera.register(P);
        var self = __plugin_instance__;
        __plugin_instance__.run_on_queue(function () { self.fired += 1; }, 250);
    `, host);

    const scheduled = host.calls.filter(c => c[0] === 'schedulePlugin');
    assert.strictEqual(scheduled.length, 1);
    // The callback itself cannot cross the bridge, only a token naming it.
    const token = scheduled[0][3];
    assert.strictEqual(typeof token, 'string');
    assert.ok(token.length > 0);
    assert.strictEqual(scheduled[0][1], 'demo');
    assert.strictEqual(scheduled[0][2], 250);

    ctx.__extera.runScheduled(token);
    assert.strictEqual(ctx.__extera.instance.fired, 1);
    // A second delivery must be a no-op: the entry was consumed on the first.
    ctx.__extera.runScheduled(token);
    assert.strictEqual(ctx.__extera.instance.fired, 1);
});

test('runScheduled ignores an unknown token', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
    `, host);
    assert.doesNotThrow(() => ctx.__extera.runScheduled('nope'));
    assert.doesNotThrow(() => ctx.__extera.runScheduled(undefined));
});

test('run_on_queue tokens are distinct per call', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        var a = __plugin_instance__.run_on_queue(function () {}, 0);
        var b = __plugin_instance__.run_on_queue(function () {}, 0);
    `, host);
    const tokens = host.calls.filter(c => c[0] === 'schedulePlugin').map(c => c[3]);
    assert.strictEqual(tokens.length, 2);
    assert.notStrictEqual(tokens[0], tokens[1]);
    assert.strictEqual(ctx.a, tokens[0]);
});

test('on_update_hook receives the update fields', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_update_hook(name, account, update) {
                this.seen = name + ":" + update.pts;
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'updateNewMessage', account: 7, field: 'update' });
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ pts: 42 }), context);
    assert.strictEqual(ctx.__extera.instance.seen, 'updateNewMessage:42');
});

test('on_updates_hook receives a bare list, like exteraGram', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_updates_hook(name, account, updates) {
                this.count = Array.isArray(updates) ? updates.length : -1;
                this.first = Array.isArray(updates) && updates.length ? updates[0].name : null;
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'updates', account: 7, field: 'updates' });
    // The host can only hand over a dictionary, so the batch arrives wrapped.
    const batch = JSON.stringify({ updates: [{ name: 'updateNewMessage', fields: {} }, { name: 'updatePts', fields: {} }] });
    ctx.__extera.runHook('on_updates_hook', batch, context);
    assert.strictEqual(ctx.__extera.instance.count, 2);
    assert.strictEqual(ctx.__extera.instance.first, 'updateNewMessage');
});

test('on_updates_hook tolerates a missing payload', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            on_updates_hook(name, account, updates) {
                this.count = Array.isArray(updates) ? updates.length : -1;
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'updates', account: 7, field: 'updates' });
    ctx.__extera.runHook('on_updates_hook', '', context);
    assert.strictEqual(ctx.__extera.instance.count, 0);
});

test('menu items are filtered by menu type, condition and priority', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.add_menu_item(new MenuItemData({
                    menu_type: "message_context_menu",
                    text: "Always",
                    priority: 1,
                    on_click: function () {},
                }));
                this.add_menu_item(new MenuItemData({
                    menu_type: "message_context_menu",
                    text: "Only Photos",
                    priority: 10,
                    condition: function (context) { return context.has_photo === true; },
                    on_click: function () {},
                }));
                this.add_menu_item(new MenuItemData({
                    menu_type: "drawer_menu",
                    text: "Elsewhere",
                    on_click: function () {},
                }));
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);

    const visible = JSON.parse(ctx.__extera.collectMenuItems('message_context_menu', JSON.stringify({ has_photo: true })));
    assert.deepStrictEqual(visible.map(i => i.text), ['Only Photos', 'Always']);

    // A condition that is false hides its item; the menu type filter drops the rest.
    const hidden = JSON.parse(ctx.__extera.collectMenuItems('message_context_menu', JSON.stringify({ has_photo: false })));
    assert.deepStrictEqual(hidden.map(i => i.text), ['Always']);
});

test('a throwing menu condition hides the item instead of breaking the menu', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.add_menu_item(new MenuItemData({
                    menu_type: "message_context_menu",
                    text: "Broken",
                    condition: function () { throw new Error("nope"); },
                    on_click: function () {},
                }));
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const visible = JSON.parse(ctx.__extera.collectMenuItems('message_context_menu', '{}'));
    assert.deepStrictEqual(visible, []);
});

test('runMenuItem invokes the click handler with the host context', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.clicked = null;
                this.id = this.add_menu_item(new MenuItemData({
                    menu_type: "message_context_menu",
                    text: "Copy",
                    on_click: (context) => { this.clicked = context.text; },
                }));
            }
        }
        var __plugin_instance__ = __extera.register(P);
        var menuItemId = __plugin_instance__.id;
    `, host);
    ctx.__extera.runMenuItem(ctx.menuItemId, JSON.stringify({ text: "hello" }));
    assert.strictEqual(ctx.__extera.instance.clicked, 'hello');
    // Unknown items are a no-op: the plugin may have removed it since.
    assert.doesNotThrow(() => ctx.__extera.runMenuItem('missing', '{}'));
});

test('parse_text returns message plus entities and honours is_caption', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
    `, host);
    const html = ctx.__extera.parseText("<b>Bold</b>, <i>Italic</i>, <a href='https://example.com'>Link</a>", "HTML", false);
    assert.strictEqual(html.message, 'Bold, Italic, Link');
    assert.deepStrictEqual(JSON.parse(JSON.stringify(html.entities)), [
        { type: 'bold', offset: 0, length: 4 },
        { type: 'italic', offset: 6, length: 6 },
        { type: 'text_link', offset: 14, length: 4, url: 'https://example.com' },
    ]);

    // HTML is the default parse mode, and `is_caption` only renames the key.
    const caption = ctx.__extera.parseText("<b>x</b>", undefined, true);
    assert.strictEqual(caption.caption, 'x');
    assert.strictEqual(caption.message, undefined);
    assert.strictEqual(caption.entities.length, 1);

    const md = ctx.__extera.parseText("**Bold**, __Under__", "Markdown", false);
    assert.strictEqual(md.message, 'Bold, Under');
    assert.deepStrictEqual(JSON.parse(JSON.stringify(md.entities)).map(e => e.type), ['bold', 'underline']);
});

test('send_text turns parse_mode into entities on the JS side', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        __plugin_instance__.send_text(123, "<b>Hello</b> world", { parse_mode: "HTML", replyToMsg: 9, notify: false });
    `, host);
    const sent = host.calls.find(c => c[0] === 'sendText');
    assert.ok(sent, 'no send reached the host');
    // id, account, peerId, text, options
    assert.strictEqual(sent[1], 'demo');
    // Account 0 stays numeric: the host resolves 0 like exteraGram's index.
    assert.strictEqual(typeof sent[2], 'number');
    assert.strictEqual(sent[3], 123);
    assert.strictEqual(sent[4], 'Hello world');
    assert.deepStrictEqual(sent[5].entities, [{ type: 'bold', offset: 0, length: 5 }]);
    assert.strictEqual(sent[5].replyToMsg, 9);
    assert.strictEqual(sent[5].notify, false);
    void ctx;
});

test('send_photo parses the caption with the same parse_mode', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        __plugin_instance__.send_photo(7, "/tmp/a.jpg", { caption: "**hi**", parse_mode: "Markdown" });
    `, host);
    const sent = host.calls.find(c => c[0] === 'sendFile');
    assert.ok(sent, 'no file send reached the host');
    assert.strictEqual(sent[3], 'photo');
    assert.strictEqual(sent[4], 7);
    assert.strictEqual(sent[5], '/tmp/a.jpg');
    assert.strictEqual(sent[6].caption, 'hi');
    assert.deepStrictEqual(sent[6].caption_entities, [{ type: 'bold', offset: 0, length: 2 }]);
    void ctx;
});

test('file_utils keeps the real value type across the bridge', () => {
    const host = makeHost();
    host.fileResults = {
        read_text: 'file body',
        exists: true,
        list_dir: ['a.txt', 'b.txt'],
        delete: null,
    };
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        var text = file_utils.read_file("/p/x.txt");
        var exists = file_utils.file_exists("/p/x.txt");
        var missing = file_utils.delete_file("/p/none.txt");
        var list = file_utils.list_dir("/p");
        var wrote = file_utils.write_file("/p/y.txt", "hello");
        var dir = file_utils.get_plugins_dir();
    `, host);
    assert.strictEqual(ctx.text, 'file body');
    assert.strictEqual(ctx.exists, true);
    assert.strictEqual(ctx.missing, null);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(ctx.list)), ['a.txt', 'b.txt']);
    assert.strictEqual(ctx.dir, '/plugins/demo');

    const write = host.calls.find(c => c[0] === 'fileOp' && c[2] === 'write_text');
    assert.strictEqual(write[3], '/p/y.txt');
    assert.strictEqual(write[4], 'hello');
    // A path is the only thing the host sees for a read; no file contents pass
    // through the plugin-visible argument list.
    const read = host.calls.find(c => c[0] === 'fileOp' && c[2] === 'read_text');
    assert.strictEqual(read[3], '/p/x.txt');
});

test('bulletins with callbacks hand the host tokens, not functions', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        var hits = 0;
        ui.bulletin.show_with_button("Saved", null, "UNDO", function () { hits += 1; }, null, ui.bulletin.DURATION_SHORT);
        ui.bulletin.show_undo("Deleted", { on_undo: function () { hits += 10; }, on_action: function () { hits += 100; } });
        ui.bulletin.show_copied_to_clipboard();
        ui.bulletin.show_file_saved_to_gallery(true, 2);
        var button = null;
        var undo = null;
        var last = null;
        for (var i = 0; i < __host.calls.length; i += 1) {
            var call = __host.calls[i];
            if (call[0] !== 'showBulletin') { continue; }
            var payload = JSON.parse(call[3]);
            if (payload.kind === 'button') { button = payload; }
            if (payload.kind === 'undo') { undo = payload; }
            last = payload;
        }
    `, host);
    assert.strictEqual(ctx.button.kind, 'button');
    assert.strictEqual(ctx.button.button, 'UNDO');
    assert.strictEqual(ctx.button.duration, 1500);
    assert.strictEqual(typeof ctx.button.token, 'string');
    assert.strictEqual(ctx.undo.kind, 'undo');
    assert.strictEqual(typeof ctx.undo.undo_token, 'string');
    assert.strictEqual(typeof ctx.undo.action_token, 'string');
    assert.strictEqual(ctx.last.kind, 'saved_gallery');
    assert.strictEqual(ctx.last.video, true);
    assert.strictEqual(ctx.last.amount, 2);

    // Tapping the button runs the callback once, through the token.
    ctx.__extera.runCallback(ctx.button.token, '[]');
    assert.strictEqual(ctx.hits, 1);
    ctx.__extera.runCallback(ctx.button.token, '[]');
    assert.strictEqual(ctx.hits, 1);
});

test('alert builder sends roles and tokens, and dismiss closes it', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        window_alert = new ui.alert.AlertDialogBuilder(null)
            .set_title("Title")
            .set_message("Body")
            .set_positive_button("Yes", function () {})
            .set_negative_button("No", function () {})
            .set_cancelable(false)
            .show();
        window_alert.dismiss();
    `, host);
    const shown = host.calls.find(c => c[0] === 'showAlert');
    assert.ok(shown, 'alert never reached the host');
    const payload = shown[2];
    assert.strictEqual(payload.title, 'Title');
    assert.strictEqual(payload.message, 'Body');
    assert.strictEqual(payload.cancelable, false);
    assert.deepStrictEqual(payload.buttons.map(b => b.role), ['negative', 'positive']);
    assert.deepStrictEqual(payload.buttons.map(b => b.text), ['No', 'Yes']);
    for (const button of payload.buttons) {
        assert.strictEqual(typeof button.token, 'string');
    }
    assert.ok(host.calls.some(c => c[0] === 'dismissAlert' && c[1] === 'demo'));
    void ctx;
});

test('Text rows report click and sub-page support to the renderer', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            create_settings() {
                return [
                    new Text({ text: "Button", on_click: function () {} }),
                    new Text({ text: "Sub", create_sub_fragment: function () { return [ new Text({ text: "Nested" }) ]; } }),
                    new Text({ text: "Plain" }),
                    new Custom({ text: "Custom button", on_long_click: function () {} }),
                ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const items = JSON.parse(ctx.__extera.collectSettings());
    assert.strictEqual(items[0].has_click, true);
    assert.strictEqual(items[0].has_sub_fragment, false);
    assert.strictEqual(items[1].has_click, false);
    assert.strictEqual(items[1].has_sub_fragment, true);
    assert.strictEqual(items[2].has_click, false);
    assert.strictEqual(items[3].has_long_click, true);
    // Every row is addressable by key, which is how a tap finds its callback.
    for (const item of items) {
        assert.strictEqual(typeof item.key, 'string');
        assert.ok(item.key.length > 0);
    }

    // Tapping the sub-page row builds the nested list through its callback.
    const sub = JSON.parse(ctx.__extera.collectSubSettings(items[1].key));
    assert.deepStrictEqual(sub.map(i => i.text), ['Nested']);
    // An unknown key yields an empty page instead of throwing.
    assert.deepStrictEqual(JSON.parse(ctx.__extera.collectSubSettings('nope')), []);
});

test('a Text row click reaches on_click with its key', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            constructor() {
                super();
                this.clicked = null;
            }
            create_settings() {
                var self = this;
                return [ new Text({ key: "open", text: "Open", on_click: function (view) { self.clicked = view.getKey(); } }) ];
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    ctx.__extera.invokeSettingCallback('open', 'click', 'null');
    assert.strictEqual(ctx.__extera.instance.clicked, 'open');
});

test('hook callbacks see both the dotted and the TL_ hook name', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            pre_request_hook(name, account, request) {
                this.seen = name;
                this.account = account;
                this.hookAccount = __extera.hookAccount();
                return new HookResult();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({
        name: 'messages.setTyping',
        tlName: 'TL_messages_setTyping',
        account: 5,
        field: 'request',
    });
    ctx.__extera.runHook('pre_request_hook', '{}', context);
    assert.strictEqual(ctx.__extera.instance.seen, 'TL_messages_setTyping');
    assert.strictEqual(ctx.__extera.instance.account, 5);
    assert.strictEqual(ctx.__extera.instance.hookAccount, 5);
    // Outside a callback the hook account is gone again.
    assert.strictEqual(ctx.__extera.hookAccount(), null);
});

test('a bare helper inside a hook uses the hook account, not the selected one', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            pre_request_hook(name, account, request) {
                this.client_account = this.client().get_account();
                this.selected = client_utils.get_selected_account();
                return new HookResult();
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'x', account: 9, field: 'request' });
    ctx.__extera.runHook('pre_request_hook', '{}', context);
    assert.strictEqual(ctx.__extera.instance.client_account, 9);
    // `get_selected_account` follows the UI selection the host pushed in.
    assert.strictEqual(ctx.__extera.instance.selected, 42);
});

test('a string menu condition is compiled and evaluated against the context', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {
            on_plugin_load() {
                // The SDK's MenuItemData takes an MVEL *string*; a JS port often
                // writes a function instead. Both have to work.
                this.add_menu_item(new MenuItemData({
                    menu_type: MenuItemType.MESSAGE_CONTEXT_MENU,
                    text: "String condition",
                    condition: "message_id > 10",
                    on_click: function () {},
                }));
                this.add_menu_item(new MenuItemData({
                    menu_type: MenuItemType.MESSAGE_CONTEXT_MENU,
                    text: "Broken condition",
                    condition: "this is not js(",
                    on_click: function () {},
                }));
            }
        });
        __extera.callLifecycleJSON('on_plugin_load', '{}');
    `, host);
    const items = (context) => JSON.parse(ctx.__extera.collectMenuItems('message_context_menu', JSON.stringify(context)));
    assert.deepStrictEqual(items({ message_id: 11 }).map(i => i.text), ['String condition']);
    assert.deepStrictEqual(items({ message_id: 3 }), []);
    // A condition that does not compile hides its item rather than breaking the
    // whole menu, and the failure is logged once.
    assert.ok(host.calls.some(c => c[0] === 'log' && c[2].includes('not valid')));

    // Functions still work, and a throwing one hides only its own item.
    const fnCtx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {
            on_plugin_load() {
                this.add_menu_item(new MenuItemData({ menu_type: MenuItemType.MESSAGE_CONTEXT_MENU, text: "Throws", condition: function () { throw new Error('no'); } }));
                this.add_menu_item(new MenuItemData({ menu_type: MenuItemType.MESSAGE_CONTEXT_MENU, text: "Always", on_click: function () {} }));
            }
        });
        __extera.callLifecycleJSON('on_plugin_load', '{}');
    `, host);
    assert.deepStrictEqual(JSON.parse(fnCtx.__extera.collectMenuItems('message_context_menu', '{}')).map(i => i.text), ['Always']);
});

test('list_dir passes the SDK options through as JSON', () => {
    const host = makeHost();
    host.fileResults = { list_dir: ['a.txt'] };
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        var positional = file_utils.list_dir("/p", true, true, true, [".txt"]);
        var object = file_utils.list_dir("/p", { recursive: true, extensions: [".png"] });
        var plain = file_utils.list_dir("/p");
    `, host);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(ctx.positional)), ['a.txt']);
    const calls = host.calls.filter(c => c[0] === 'fileOp' && c[2] === 'list_dir');
    assert.deepStrictEqual(JSON.parse(calls[0][4]), { recursive: true, include_files: true, include_dirs: true, extensions: ['.txt'] });
    assert.deepStrictEqual(JSON.parse(calls[1][4]), { recursive: true, extensions: ['.png'] });
    assert.deepStrictEqual(JSON.parse(calls[2][4]), {});
});

test('run_on_queue keeps the hook account in scope for the delayed work', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        class P extends BasePlugin {
            pre_request_hook(name, account, request) {
                // A hook schedules a reply a few seconds later; without a
                // captured scope it would send from whichever account is
                // selected by the time it runs.
                this.run_on_queue(function () {
                    this.seen_hook_account = __extera.hookAccount();
                    this.seen_client_account = this.client().get_account();
                }.bind(this), 500);
                return null;
            }
        }
        var __plugin_instance__ = __extera.register(P);
    `, host);
    const context = JSON.stringify({ name: 'x', account: 7, field: 'request' });
    ctx.__extera.runHook('pre_request_hook', '{}', context);
    const scheduled = host.calls.filter(c => c[0] === 'schedulePlugin');
    assert.strictEqual(scheduled.length, 1);
    ctx.__extera.runScheduled(scheduled[0][3]);
    assert.strictEqual(ctx.__extera.instance.seen_hook_account, 7);
    assert.strictEqual(ctx.__extera.instance.seen_client_account, 7);
    // The scope is restored, not left behind for the next callback.
    assert.strictEqual(ctx.__extera.hookAccount(), null);
});

test('copy_to_clipboard and the android_utils wrappers reach the host', () => {
    const host = makeHost();
    host.copyToClipboard = (id, text) => host.calls.push(['copyToClipboard', id, text]);
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        android_utils.copy_to_clipboard("t.me/exteraPlugins");
        var listener = android_utils.OnClickListener(function () { return 1; });
        var runnable = android_utils.R(function () { return 2; });
    `, host);
    const copy = host.calls.find(c => c[0] === 'copyToClipboard');
    assert.deepStrictEqual(copy, ['copyToClipboard', 'demo', 't.me/exteraPlugins']);
    // The Java-listener wrappers return a callable, so passing one around and
    // calling it later still works.
    assert.strictEqual(ctx.listener(), 1);
    assert.strictEqual(ctx.runnable(), 2);
    void ctx;
});

test('BulletinHelper, a string condition and the Java-proxy stubs keep their shape', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        ui.bulletin.BulletinHelper.show_info("via helper");
        var proxy = extera_utils.classes;
        var decorated = proxy.joverride("x")("x");
        var base = proxy.Base;
        var field = proxy.jfield("int", 0);
    `, host);
    const bulletin = host.calls.find(c => c[0] === 'showBulletin');
    assert.strictEqual(JSON.parse(bulletin[3]).text, 'via helper');
    assert.strictEqual(ctx.decorated, 'x');
    assert.strictEqual(ctx.field, 0);
    // `java_subclass` exists so the decorator syntax parses; instantiating the
    // generated class fails loudly instead of pretending to be a Java object.
    assert.throws(() => ctx.__extera.api && ctx.extera_utils.classes.jclassbuilder()(), /Java/);
});

test('FilesController registers, rejects duplicates and unregisters', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        var __plugin_instance__ = __extera.register(class P extends BasePlugin {});
        var secret = file_utils.FilesController.register(
            new file_utils.FilesController.FileInfo({ ext: ".zip", on_click: function () {} })
        );
        var duplicate = null;
        try {
            file_utils.FilesController.register(new file_utils.FilesController.FileInfo({ ext: "zip" }));
        } catch (error) {
            duplicate = error.name;
        }
        file_utils.FilesController.unregister("zip", secret);
        var wrongSecret = null;
        file_utils.FilesController.register(new file_utils.FilesController.FileInfo({ ext: "txt" }));
        try {
            file_utils.FilesController.unregister("txt", "nope");
        } catch (error) {
            wrongSecret = error.name;
        }
    `, host);
    assert.strictEqual(typeof ctx.secret, 'string');
    assert.strictEqual(ctx.duplicate, 'ExtensionAlreadyRegistered');
    assert.strictEqual(ctx.wrongSecret, 'SecretInvalid');
    assert.strictEqual(ctx.file_utils.FilesController.SUPPORT_ICONS, false);
    // Registering is honest about not intercepting anything on iOS.
    assert.ok(host.calls.some(c => c[0] === 'log' && c[2].includes('cannot intercept')));
});

let failed = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed += 1;
        console.log('FAIL ' + name);
        console.log('     ' + error.message);
    }
}
console.log(failed === 0 ? `\n${tests.length} passed` : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);