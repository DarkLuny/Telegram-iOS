/*
 * Runs js/proxy_sub.plugin through the real bootstrap against a fake __host,
 * with a fake subscription source and a fake proxy list.
 *
 * This is a behavioural test of the port, not of the bootstrap: it drives the
 * settings screen, the fetch, the filter, the export and the delete flow the way
 * the plugin's own callbacks do, and asserts on what reached the host.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'proxy_sub.plugin'), 'utf8');

const SOURCE = [
    { server: '1.2.3.4', port: 443, secret: 'ee' + 'a'.repeat(32), country: 'DE' },
    { server: '1.2.3.5', port: 443, secret: 'bb'.repeat(16), country: 'NL' },
    { server: 'web.example.com', secret: 'ee' + 'c'.repeat(32), via: 'websocket', country: 'US' },
    { garbage: true },
];

function makeHost(options) {
    options = options || {};
    const calls = [];
    const settings = Object.assign({}, options.settings || {});
    const state = {
        calls,
        settings,
        sends: [],
        documents: [],
        bulletins: [],
        alerts: [],
        dialogs: [],
        files: {},
        pending: {},
        proxies: options.proxies || [],
        sources: options.sources || { 0: SOURCE },
    };

    const host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: (id, key) => (key in settings ? settings[key] : null),
        setSetting: (id, key, value) => { settings[key] = value; calls.push(['setSetting', id, key, value]); return true; },
        exportSettings: () => ({ ...settings }),
        importSettings: (id, values) => { Object.assign(settings, values); },
        addHook: () => {},
        addOnSendMessageHook: () => {},
        addMenuItem: () => 'item',
        removeMenuItem: () => {},
        sendText: (id, account, peerId, text, opts) => {
            state.sends.push({ peerId, text, options: JSON.parse(opts || '{}') });
        },
        sendFile: (id, account, kind, peerId, p, opts) => {
            state.documents.push({ kind, peerId, path: p, options: JSON.parse(opts || '{}') });
        },
        showBulletin: (id, kind, text) => {
            // The bootstrap sends one JSON object; `kind` is the fallback.
            let payload;
            try { payload = JSON.parse(text); } catch (error) { payload = { kind, text }; }
            state.bulletins.push({ kind: payload.kind || kind, text: payload.text, raw: payload });
        },
        showAlert: (id, json) => {
            const payload = JSON.parse(json);
            state.alerts.push(payload);
            // The alert is presented; the test answers it explicitly.
            state.lastAlert = payload;
        },
        dismissAlert: (id) => {
            if (state.lastAlert) {
                state.lastAlert.dismissed = true;
            }
        },
        fileOp: (id, op, p, payload) => {
            calls.push(['fileOp', id, op, p, payload]);
            if (op === 'write_text') {
                state.files[p] = payload;
                return 'true';
            }
            if (op === 'read_text') {
                return JSON.stringify(p in state.files ? state.files[p] : null);
            }
            return 'null';
        },
        selectedAccount: () => 0,
        pluginDirectory: () => '/plugins/proxy_sub',
        schedulePlugin: () => {},
        httpGet: (id, url, headers, timeout, token) => {
            calls.push(['httpGet', id, url, JSON.parse(headers), timeout]);
            const index = SOURCE_URLS.indexOf(url);
            state.pending.http = { token, index, url };
            if (!(index in state.sources) || state.sources[index] === null) {
                // A failed source answers the way PluginHttpAccess does.
                vm.runInContext(
                    '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: false, error: 'unreachable' })) + ')',
                    state.context
                );
                return;
            }
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, status: 200, text: JSON.stringify(state.sources[index]), headers: {} })) + ')',
                state.context
            );
        },
        proxyList: (id, token) => {
            calls.push(['proxyList', id]);
            state.pending.list = token;
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, servers: state.proxies })) + ')',
                state.context
            );
        },
        proxyAdd: (id, links, token) => {
            const parsed = JSON.parse(links);
            calls.push(['proxyAdd', id, parsed]);
            state.added = parsed;
            let added = 0;
            const duplicates = 0;
            const invalid = 0;
            for (const link of parsed) {
                if (!state.proxies.some((s) => s.link === link)) {
                    added += 1;
                    state.proxies.push({ link, kind: link.includes('webproxy') ? 'web' : 'mtproto', host: 'h', port: 443 });
                }
            }
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, added, duplicates, invalid })) + ')',
                state.context
            );
        },
        proxyRemoveAll: (id, token) => {
            calls.push(['proxyRemoveAll', id]);
            const removed = state.proxies.length;
            state.proxies = [];
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, removed })) + ')',
                state.context
            );
        },
        ownPeerId: (id, account, token) => {
            calls.push(['ownPeerId', id, account]);
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, peer_id: 777 })) + ')',
                state.context
            );
        },
        // Test helpers
        resolveAll: () => {},
    };
    state.host = host;
    return state;
}

const SOURCE_URLS = [
    'https://gitverse.ru/api/repos/Akres/Proxy/raw/branch/master/proxies.json',
    'https://github.com/theakres/Proxy/raw/main/proxies.json',
];

function load(state) {
    const context = vm.createContext({ __host: state.host, console });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('proxy_sub', 'Proxy Sub');
    vm.runInContext(plugin, context, { filename: 'proxy_sub.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

function settingsOf(context) {
    return JSON.parse(context.__extera.collectSettings());
}

// Clicks a Text row by its label, through the key the settings renderer
// actually uses. The key is derived from the text, and a Cyrillic label
// collapses to a positional __N, so looking it up is the only way to reach
// the row without duplicating that derivation in the test.
function clickRow(state, ctx, text) {
    const control = settingsOf(ctx).find((c) => c.type === 'text' && c.text === text);
    assert.ok(control, 'no Text row labelled ' + text);
    ctx.__extera.invokeSettingCallback(control.key, 'click', 'null');
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const state = makeHost();
    load(state);
    const manifest = {
        id: state.context.__id__,
        name: state.context.__name__,
        version: state.context.__version__,
        author: state.context.__author__,
    };
    assert.strictEqual(manifest.id, 'proxy_sub');
    assert.strictEqual(manifest.name, 'Proxy Sub');
    assert.strictEqual(manifest.version, '3.0.2');
    assert.strictEqual(manifest.author, '@akresik');
});

test('the first screen offers the source selector and the stats button', () => {
    const state = makeHost();
    const ctx = load(state);
    const controls = settingsOf(ctx);
    const selector = controls.find((c) => c.type === 'selector');
    assert.strictEqual(selector.key, 'proxy_source');
    assert.deepStrictEqual(Array.from(selector.items), ['GitVerse', 'GitHub']);
    assert.ok(controls.some((c) => c.type === 'text' && c.text === 'Список протоколов и стран'));
    // No protocol switch before the source was read.
    assert.ok(!controls.some((c) => c.type === 'switch' && c.key === 'mtproto_faketls'));
});

test('fetching stats fills the protocol counters and resets filters', () => {
    const state = makeHost();
    const ctx = load(state);
    // Drive the button the way the settings renderer does.
    clickRow(state, ctx, 'Список протоколов и стран');
    assert.ok(state.bulletins.some((b) => b.kind === 'info' && b.text.includes('Загружаем списки')));
    const controls = settingsOf(ctx);
    const keys = controls.filter((c) => c.type === 'switch').map((c) => c.key);
    assert.ok(keys.includes('mtproto_faketls'));
    assert.ok(keys.includes('mtproto_padding'));
    assert.ok(keys.includes('web_websocket'));
    const text = controls.filter((c) => c.type === 'switch').map((c) => c.text).join(' | ');
    assert.ok(text.includes('FakeTLS (1)'), text);
    assert.ok(text.includes('Padding (1)'), text);
    assert.ok(text.includes('WebSocket (1)'), text);
    // The filter existed before this fetch, so the reset had something to clear.
    assert.strictEqual(state.settings.mtproto_faketls, false);
});

test('country mode lists every country from the source', () => {
    const state = makeHost({ settings: { filter_enabled: true, fetch_mode: 1 } });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    const controls = settingsOf(ctx);
    const countries = controls.filter((c) => c.type === 'switch' && c.key.indexOf('country_') === 0);
    const codes = countries.map((c) => c.key.replace('country_', '')).sort();
    assert.deepStrictEqual(codes, ['DE', 'NL', 'US']);
    assert.ok(countries.some((c) => c.text.includes('Германия')));
    assert.ok(countries.some((c) => c.text.includes('🇩🇪')));
});

test('a protocol filter narrows what is added', () => {
    const state = makeHost({
        settings: {
            filter_enabled: true,
            fetch_mode: 0,
            mtproto_faketls: true,
            mtproto_padding: false,
            web_websocket: false,
        },
    });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    // The stats fetch resets the protocol switches, so set them again after it.
    state.settings.mtproto_faketls = true;
    clickRow(state, ctx, 'Получить новый список');
    assert.ok(state.added, 'the plugin added something');
    assert.strictEqual(state.added.length, 1);
    assert.ok(state.added[0].includes('1.2.3.4'));
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('Добавлено: 1')));
});

test('an empty selection is refused with a clear message', () => {
    const state = makeHost({ settings: { filter_enabled: true, fetch_mode: 0 } });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    state.settings.mtproto_faketls = false;
    state.settings.mtproto_padding = false;
    state.settings.web_websocket = false;
    clickRow(state, ctx, 'Получить новый список');
    assert.ok(state.bulletins.some((b) => b.text === 'Выберите хотя бы один протокол.'));
    assert.strictEqual(state.added, undefined);
});

test('the second source is used when the first fails', () => {
    const state = makeHost({ sources: { 0: null, 1: SOURCE } });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    const attempts = state.calls.filter((c) => c[0] === 'httpGet').map((c) => c[2]);
    assert.strictEqual(attempts[0], SOURCE_URLS[0]);
    assert.strictEqual(attempts[1], SOURCE_URLS[1]);
    assert.ok(settingsOf(ctx).some((c) => c.type === 'switch' && c.key === 'mtproto_faketls'));
});

test('both sources failing reports an error', () => {
    const state = makeHost({ sources: { 0: null, 1: null } });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('Не удалось загрузить списки')));
});

test('export sends a formatted message to Saved Messages', () => {
    const state = makeHost({
        proxies: [
            { link: 'tg://proxy?server=5.6.7.8&port=443&secret=ee' + '11'.repeat(16), kind: 'mtproto', host: '5.6.7.8', port: 443 },
            { link: 'tg://proxy?server=1.1.1.1&port=443&secret=' + '22'.repeat(16), kind: 'mtproto', host: '1.1.1.1', port: 443 },
            { link: 'tg://webproxy?server=w.example.com&secret=ee' + '33'.repeat(16), kind: 'web', host: 'w.example.com', port: 443 },
        ],
    });
    const ctx = load(state);
    clickRow(state, ctx, 'Экспортировать прокси');
    assert.strictEqual(state.sends.length, 1, 'one message');
    const sent = state.sends[0];
    assert.strictEqual(sent.peerId, 777, 'Saved Messages');
    assert.ok(sent.text.startsWith('FakeTLS (MTP):\n'), sent.text);
    assert.ok(sent.text.includes('Padding (MTP):'), sent.text);
    assert.ok(sent.text.includes('WebProxy:'), sent.text);
    // FakeTLS first, then padding, then web: the original's section order.
    assert.ok(sent.text.indexOf('5.6.7.8') < sent.text.indexOf('Padding'), 'faketls before padding');
    assert.ok(sent.options.entities.length === 4, JSON.stringify(sent.options.entities));
    const kinds = sent.options.entities.map((e) => e.type);
    assert.ok(kinds.includes('bold'));
    assert.ok(kinds.includes('blockquote'));
    const quote = sent.options.entities.find((e) => e.type === 'blockquote');
    assert.strictEqual(quote.collapsed, true);
    assert.strictEqual(quote.length, sent.text.length);
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('3 прокси')));
});

test('a long export goes as a file', () => {
    const state = makeHost();
    const many = [];
    for (let i = 0; i < 200; i += 1) {
        many.push({
            link: 'tg://proxy?server=10.0.0.' + i + '&port=443&secret=' + 'ab'.repeat(16),
            kind: 'mtproto',
            host: '10.0.0.' + i,
            port: 443,
        });
    }
    state.proxies = many;
    const ctx = load(state);
    clickRow(state, ctx, 'Экспортировать прокси');
    assert.strictEqual(state.sends.length, 0, 'no message for a long list');
    assert.strictEqual(state.documents.length, 1, 'one document');
    assert.ok(state.documents[0].path.startsWith('/plugins/proxy_sub/proxy-'));
    assert.ok(state.documents[0].path.endsWith('.txt'));
    assert.ok(state.files[state.documents[0].path].includes('tg://proxy?server='));
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('файлом')));
});

test('exporting an empty list says so', () => {
    const state = makeHost({ proxies: [] });
    const ctx = load(state);
    clickRow(state, ctx, 'Экспортировать прокси');
    assert.strictEqual(state.sends.length, 0);
    assert.ok(state.bulletins.some((b) => b.text === 'Нет прокси для экспорта.'));
});

test('delete asks first, then removes everything', () => {
    const state = makeHost({
        proxies: [{ link: 'tg://proxy?server=a&port=443&secret=' + 'aa'.repeat(16), kind: 'mtproto', host: 'a', port: 443 }],
    });
    const ctx = load(state);
    clickRow(state, ctx, 'Удалить все прокси');
    assert.strictEqual(state.alerts.length, 1);
    assert.strictEqual(state.lastAlert.title, 'Удалить все прокси?');
    assert.ok(state.lastAlert.message.includes('(1)'));
    // Nothing is removed until the positive button is pressed.
    assert.strictEqual(state.proxies.length, 1);
    const positive = state.lastAlert.buttons.find((b) => b.role === 'positive');
    ctx.__extera.runCallback(positive.token, '[]');
    assert.strictEqual(state.proxies.length, 0);
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('Удалено прокси: 1')));
});

test('deleting an empty list says so instead of showing a dialog', () => {
    const state = makeHost({ proxies: [] });
    const ctx = load(state);
    clickRow(state, ctx, 'Удалить все прокси');
    assert.strictEqual(state.alerts.length, 0);
    assert.ok(state.bulletins.some((b) => b.text === 'Нет прокси для удаления.'));
});

test('settings screen reports the filter controls only when enabled', () => {
    const state = makeHost();
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    // With the filter on, the mode selector and the divider are present.
    let controls = settingsOf(ctx);
    assert.ok(controls.some((c) => c.type === 'selector' && c.key === 'fetch_mode'));
    assert.ok(controls.some((c) => c.type === 'switch' && c.key === 'filter_enabled'));
    // Turn it off: the protocols disappear and the divider explains why.
    state.settings.filter_enabled = false;
    controls = settingsOf(ctx);
    assert.ok(!controls.some((c) => c.key === 'fetch_mode'));
    assert.ok(!controls.some((c) => c.key === 'mtproto_faketls'));
    assert.ok(controls.some((c) => c.type === 'divider' && String(c.text).includes('Без фильтра')));
});

test('the source index in settings decides which URL is tried first', () => {
    const state = makeHost({ settings: { proxy_source: 1 } });
    const ctx = load(state);
    clickRow(state, ctx, 'Список протоколов и стран');
    assert.strictEqual(state.calls.filter((c) => c[0] === 'httpGet')[0][2], SOURCE_URLS[1]);
});

let failed = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed += 1;
        console.log('FAIL ' + name);
        console.log('     ' + (error && error.message));
    }
}
console.log(failed === 0 ? '\n' + tests.length + ' passed' : '\n' + failed + ' failed');
process.exit(failed === 0 ? 0 : 1);