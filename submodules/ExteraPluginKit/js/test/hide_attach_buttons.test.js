/*
 * Runs js/hide_attach_buttons.plugin through the real bootstrap against a fake
 * __host, and drives `on_attach_menu_hook` the way PluginManager does.
 *
 * The Android original hid views after the sheet was built; here the keys are
 * filtered before the host builds it. What this pins down is that the mapping
 * from the plugin's setting names to the iOS button keys is right (a wrong key
 * would silently hide nothing), that a bot key is only removed when the "hide all
 * bots" switch is on, and that the one Android-only switch does not claim to work.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'hide_attach_buttons.plugin'), 'utf8');

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
            pluginDirectory: () => '/plugins/hide_attach_buttons',
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
    context.__extera.setIdentity('hide_attach_buttons', 'Hide Attach Buttons');
    vm.runInContext(plugin, context, { filename: 'hide_attach_buttons.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

// The keys `AttachmentButtonType.key` reports, as the host builds the sheet.
const OFFERED = ['gallery', 'file', 'money', 'location', 'todo', 'quickReply',
    'contact', 'poll', 'app_wallet', 'gift', 'sticker', 'emoji', 'audio',
    'link', 'richText', 'standalone'];

// Mirrors PluginManager.dispatchAttachMenuExclusions: ask the plugin with the
// offered keys and keep the answer's subset, in the order it was offered.
function filter(ctx, offered) {
    const answer = JSON.parse(ctx.__extera.query(
        'on_attach_menu_hook',
        JSON.stringify({ keys: offered }),
        JSON.stringify({ account: 0, peer: 1 })
    ));
    if (answer.value === null || answer.value === undefined) {
        return offered;
    }
    const kept = new Set(answer.value);
    return offered.filter((key) => kept.has(key));
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 'hide_attach_buttons');
    assert.strictEqual(ctx.__name__, 'Hide Attach Buttons');
    assert.strictEqual(ctx.__version__, '1.2');
    assert.strictEqual(ctx.__author__, 'Natu');
});

test('nothing is filtered while every switch is off', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.deepStrictEqual(Array.from(filter(ctx, OFFERED)), OFFERED);
});

test('each switch removes its own iOS key and nothing else', () => {
    const cases = [
        ['hide_gallery', ['gallery']],
        ['hide_music', ['audio']],
        ['hide_document', ['file']],
        ['hide_contact', ['contact']],
        ['hide_location', ['location']],
        ['hide_poll', ['poll']],
        ['hide_quick_replies', ['quickReply']],
    ];
    for (const [setting, removed] of cases) {
        const state = makeHost({ [setting]: true });
        const ctx = load(state);
        const kept = filter(ctx, OFFERED);
        assert.deepStrictEqual(
            OFFERED.filter((key) => kept.indexOf(key) < 0),
            removed,
            setting
        );
    }
});

test('the article switch removes the editor and the list switch the todo screen', () => {
    // `richText` is the article composer, `todo` the list screen; the original's
    // `hide_article` and `hide_list` are separate switches for the same two.
    let state = makeHost({ hide_article: true });
    let kept = filter(load(state), OFFERED);
    assert.ok(kept.indexOf('richText') < 0);
    assert.ok(kept.indexOf('todo') >= 0, 'the article switch must not remove the list screen');

    state = makeHost({ hide_list: true });
    kept = filter(load(state), OFFERED);
    assert.ok(kept.indexOf('todo') < 0);
    assert.ok(kept.indexOf('richText') >= 0, 'the list switch must not remove the article editor');
});

test('a bot is only hidden when the bots switch is on', () => {
    let state = makeHost();
    let kept = filter(load(state), OFFERED);
    assert.ok(kept.indexOf('app_wallet') >= 0);

    state = makeHost({ hide_all_bots: true });
    kept = filter(load(state), OFFERED);
    // `money` and `gift` are built-in entries, not `app_*`, so they stay.
    assert.ok(kept.indexOf('app_wallet') < 0);
    assert.ok(kept.indexOf('money') >= 0);
    assert.ok(kept.indexOf('gift') >= 0);
});

test('the hook keeps the offered order and never invents a key', () => {
    const state = makeHost({ hide_gallery: true, hide_poll: true });
    const ctx = load(state);
    const kept = filter(ctx, OFFERED);
    assert.deepStrictEqual(kept, OFFERED.filter((key) => key !== 'gallery' && key !== 'poll'));
});

test('an unknown offered key is left alone, so a new button still shows', () => {
    const state = makeHost({ hide_gallery: true });
    const ctx = load(state);
    const offered = ['gallery', 'brandNewButton'];
    assert.deepStrictEqual(Array.from(filter(ctx, offered)), ['brandNewButton']);
});

test('an unloaded plugin answers nothing, so no button is hidden by a dead plugin', () => {
    const state = makeHost({ hide_gallery: true });
    const ctx = load(state);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.deepStrictEqual(Array.from(filter(ctx, OFFERED)), OFFERED);
});

test('the settings screen carries the original nine switches plus the two extras', () => {
    const state = makeHost();
    const ctx = load(state);
    const keys = settingsOf(ctx)
        .filter((c) => c.type === 'switch')
        .map((c) => c.key);
    for (const key of ['hide_gallery', 'hide_music', 'hide_document', 'hide_contact',
        'hide_location', 'hide_poll', 'hide_quick_replies', 'hide_article', 'hide_list',
        'hide_all_bots', 'md3_style']) {
        assert.ok(keys.indexOf(key) >= 0, key);
    }
});

test('the section headers carry their text, not an empty label', () => {
    // `Header(...)` takes an options object; calling it with a bare string leaves
    // `text` undefined, and the screen shows three blank headings instead of
    // "Стандартные кнопки", "Боты и мини-приложения" and "Стиль".
    const state = makeHost();
    const ctx = load(state);
    const headers = settingsOf(ctx).filter((c) => c.type === 'header').map((c) => c.text);
    assert.deepStrictEqual(headers, ['Стандартные кнопки', 'Боты и мини-приложения', 'Стиль']);
});

test('the Android-only style switch says it does nothing here', () => {
    const state = makeHost();
    const ctx = load(state);
    const row = settingsOf(ctx).find((c) => c.key === 'md3_style');
    assert.ok(row, 'the switch is stored, not dropped');
    assert.ok(row.text.includes('не действует'), row.text);
    assert.ok(row.subtext && row.subtext.includes('iOS'), String(row.subtext));
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