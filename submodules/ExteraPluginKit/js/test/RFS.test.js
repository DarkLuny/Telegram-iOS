/*
 * Runs js/RFS.plugin through the real bootstrap against a fake __host, and drives
 * `on_allow_screenshots` the way PluginManager.dispatchAllowScreenshots does.
 *
 * The Android original hooked Android classes; there are none here, so what this
 * pins down is the contract the host actually reads: the switch turns the answer
 * on and off, a false answer never claims to allow anything, and an unloaded
 * plugin stops answering — because a dead plugin that still answered `true` would
 * keep the screenshots allowed for the rest of the session.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'RFS.plugin'), 'utf8');

function makeHost(settings) {
    const calls = [];
    const store = Object.assign({}, settings || {});
    return {
        calls,
        store,
        host: {
            log: (id, text) => calls.push(['log', id, text]),
            getSetting: (id, key) => (key in store ? store[key] : null),
            setSetting: (id, key, value) => { store[key] = value; return true; },
            exportSettings: () => ({ ...store }),
            importSettings: (id, values) => { Object.assign(store, values); },
            addHook: () => {},
            addOnSendMessageHook: () => {},
            addMenuItem: () => 'item',
            removeMenuItem: () => {},
            sendText: () => {},
            sendFile: () => {},
            editMessage: () => {},
            showBulletin: () => {},
            showAlert: () => {},
            dismissAlert: () => {},
            fileOp: () => 'null',
            selectedAccount: () => 0,
            appVersion: () => '13.1.1',
            pluginDirectory: () => '/plugins/RFS',
            schedulePlugin: () => {},
            openUrl: () => true,
            themeColors: () => '{}',
            httpGet: () => {},
            proxyList: () => {},
            proxyAdd: () => {},
            proxyRemoveAll: () => {},
            ownPeerId: () => {},
        },
    };
}

function load(state) {
    const context = vm.createContext({ __host: state.host, console });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('RFS', 'Remove Flag Secure');
    vm.runInContext(plugin, context, { filename: 'RFS.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

// Mirrors PluginManager.dispatchAllowScreenshots: ask, and only an explicit
// truthy answer means "allow".
function allows(ctx) {
    const answer = JSON.parse(ctx.__extera.query(
        'on_allow_screenshots',
        'null',
        JSON.stringify({ account: 0 })
    ));
    if (answer.value === null || answer.value === undefined) {
        return false;
    }
    return answer.value === true;
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.__id__, 'RFS');
    assert.strictEqual(ctx.__name__, 'Remove Flag Secure');
    assert.strictEqual(ctx.__version__, '1.1');
    assert.strictEqual(ctx.__author__, '@kvucoplugins');
    assert.strictEqual(ctx.__app_version__, '>=12.5.1');
});

test('a fresh install allows screenshots, as installing the Android plugin did', () => {
    const ctx = load(makeHost());
    assert.strictEqual(allows(ctx), true);
});

test('the switch turns the answer off and on', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.instance.set_setting('allow_screenshots', false);
    assert.strictEqual(allows(ctx), false);

    ctx.__extera.instance.set_setting('allow_screenshots', true);
    assert.strictEqual(allows(ctx), true);
});

test('a stored 1 counts as on, not as a truthy value that never compares equal', () => {
    // `CFBoolean` reaches JavaScriptCore as a number on some paths. The Android
    // original's `bool(get_setting(...))` accepted that; a strict `=== true`
    // would read "off" for a switch the user had turned on.
    const ctx = load(makeHost({ allow_screenshots: 1 }));
    assert.strictEqual(allows(ctx), true);
});

test('an unloaded plugin answers nothing, so it cannot keep screenshots allowed', () => {
    const ctx = load(makeHost());
    assert.strictEqual(allows(ctx), true);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.strictEqual(allows(ctx), false);
});

test('the plugin implements the callback the host asks for', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.__extera.hasHook('on_allow_screenshots'), true);
});

test('the settings screen has one working switch and says what is not ported', () => {
    const ctx = load(makeHost());
    const controls = settingsOf(ctx);
    const switches = controls.filter((c) => c.type === 'switch');
    assert.strictEqual(switches.length, 1);
    assert.strictEqual(switches[0].key, 'allow_screenshots');
    assert.strictEqual(switches[0].default, true);

    const texts = controls.filter((c) => c.type === 'text').map((c) => c.text);
    assert.ok(texts.some((text) => text.indexOf('Запрет копирования') >= 0), String(texts));
    assert.ok(texts.some((text) => text.indexOf('Отчёт о скриншоте') >= 0), String(texts));
});

test('loading says that the Android hooks have no direct counterpart', () => {
    // The original hooked nine Android methods by name. Silence here would read
    // as "all nine were hooked", which is the one thing that is not true.
    const state = makeHost();
    load(state);
    const logged = state.calls.filter((call) => call[0] === 'log').map((call) => call[2]);
    assert.ok(logged.some((text) => text.indexOf('FLAG_SECURE') >= 0), String(logged));
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
console.log(failed === 0 ? `\n${tests.length} passed` : `\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed === 0 ? 0 : 1);