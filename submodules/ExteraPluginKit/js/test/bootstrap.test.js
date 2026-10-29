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
        sendText: (id, peerId, text, opts) => calls.push(['sendText', id, peerId, text]),
        sendFile: (id, kind, peerId, p) => calls.push(['sendFile', id, kind, peerId, p]),
        showBulletin: (id, kind, text) => calls.push(['showBulletin', id, kind, text]),
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