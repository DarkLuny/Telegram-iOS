/*
 * Runs js/tg_ws_proxy.plugin through the real bootstrap against a fake __host,
 * with a fake Documents directory and a fake CloudFlare front.
 *
 * The behaviour under test is the automatic one: enabling the plugin picks a
 * zone by itself and writes the document the client build reads, disabling it
 * removes the document, and the screen reports what the client confirmed. The
 * fake front answers through the bridge's token, the same way the host's
 * URLSession does.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'tg_ws_proxy.plugin'), 'utf8');

const CONFIG_PATH = '/documents/tg_ws_proxy.json';
const STATUS_PATH = '/documents/tg_ws_proxy_status.json';

const DOMAINS = [
    'pclead.co.uk',
    'offshor.co.uk',
    'cakeisalie.co.uk',
    'noskomnadzor.co.uk',
    'lovetrue.co.uk',
];

function makeHost(options) {
    options = options || {};
    const calls = [];
    const settings = Object.assign({}, options.settings || {});
    const state = {
        calls,
        settings,
        files: Object.assign({}, options.files || {}),
        bulletins: [],
        http: [],
        clipboard: [],
        opened: [],
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
        showBulletin: (id, kind, text) => {
            let payload;
            try { payload = JSON.parse(text); } catch (error) { payload = { kind, text }; }
            state.bulletins.push({ kind: payload.kind || kind, text: payload.text, raw: payload });
        },
        showAlert: () => {},
        dismissAlert: () => {},
        fileOp: (id, op, p, payload) => {
            calls.push(['fileOp', id, op, p, payload]);
            if (op === 'documents_dir') {
                return JSON.stringify('/documents');
            }
            if (op === 'write_text') {
                state.files[p] = payload;
                return 'true';
            }
            if (op === 'read_text') {
                return JSON.stringify(p in state.files ? state.files[p] : null);
            }
            if (op === 'delete') {
                delete state.files[p];
                return 'true';
            }
            if (op === 'exists') {
                return JSON.stringify(p in state.files);
            }
            return 'null';
        },
        selectedAccount: () => 0,
        pluginDirectory: () => '/plugins/tg_ws_proxy',
        schedulePlugin: () => {},
        copyToClipboard: (id, text) => { state.clipboard.push(text); return true; },
        openUrl: (id, url) => { state.opened.push(url); return true; },
        // Answers through the token the bootstrap hands out, exactly as the
        // host's URLSession bridge does. `options.front` decides the status.
        httpGet: (id, url, headers, timeout, token) => {
            state.http.push({ url, headers: JSON.parse(headers), timeout });
            const answer = options.front ? options.front(url) : { ok: false, status: 0, error: 'unreachable' };
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' +
                    JSON.stringify(JSON.stringify(answer)) + ')',
                state.context
            );
        },
    };
    state.host = host;
    return state;
}

function load(state) {
    const context = vm.createContext({ __host: state.host, console });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('tg_ws_proxy', 'TG WS Proxy');
    vm.runInContext(plugin, context, { filename: 'tg_ws_proxy.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

function settingsOf(context) {
    return JSON.parse(context.__extera.collectSettings());
}

function controlByKey(ctx, key) {
    const control = settingsOf(ctx).find((c) => c.key === key);
    assert.ok(control, 'no control with key ' + key);
    return control;
}

function clickKey(ctx, key) {
    const control = controlByKey(ctx, key);
    ctx.__extera.invokeSettingCallback(control.key, 'click', 'null');
    return control;
}

// What the host does when the user moves a switch or picks a list item: the
// value is stored first, then the plugin's change callback runs.
function changeSetting(state, ctx, key, value) {
    state.settings[key] = value;
    ctx.__extera.invokeSettingCallback(key, 'change', JSON.stringify({ value: value }));
}

function configOf(state) {
    const written = state.files[CONFIG_PATH];
    return written ? JSON.parse(written) : null;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the plugin file', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 'tg_ws_proxy');
    assert.strictEqual(ctx.__name__, 'TG WS Proxy');
    assert.strictEqual(ctx.__version__, '2.1.0');
});

test('tg-ws-proxy zone list decodes to the five co.uk zones', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    const decoded = vm.runInContext('defaultCfproxyDomains()', ctx);
    assert.deepStrictEqual(Array.from(decoded), DOMAINS);
    assert.ok(decoded.every((d) => d.endsWith('.co.uk')));
});

test('the screen is the automatic one: no Apply, a default-on switch', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    const controls = settingsOf(ctx);
    const enable = controls.find((c) => c.type === 'switch' && c.key === 'enabled');
    assert.ok(enable, 'no enabled switch');
    assert.strictEqual(enable.default, true);
    const selector = controls.find((c) => c.type === 'selector' && c.key === 'domain_index');
    assert.ok(selector, 'no domain selector');
    assert.deepStrictEqual(Array.from(selector.items), ['Автоматически'].concat(DOMAINS));
    assert.ok(controls.some((c) => c.key === 'connect' && c.type === 'text'));
    assert.ok(!controls.some((c) => c.type === 'text' && c.text === 'Применить'));
    assert.ok(!controls.some((c) => c.key === 'restart_note'));
    assert.ok(!(CONFIG_PATH in state.files));
});

test('enabling connects by itself: probes every zone, takes the first that answers', () => {
    const state = makeHost({
        settings: { enabled: false },
        front: (url) => (url.includes('pclead') ? { ok: false, status: 0 } : { ok: false, status: 404 }),
    });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0, 'loading a disabled plugin probed something');
    changeSetting(state, ctx, 'enabled', true);
    assert.strictEqual(state.http.length, DOMAINS.length);
    assert.deepStrictEqual(
        state.http.map((r) => r.url),
        DOMAINS.map((d) => 'https://kws2.' + d + '/')
    );
    assert.ok(state.http.every((r) => r.timeout === 4));
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'offshor.co.uk' });
    assert.strictEqual(state.settings.last_domain, 'offshor.co.uk');
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('offshor.co.uk')), JSON.stringify(state.bulletins));
});

test('a five-hundred answer from the edge is not a working zone', () => {
    const state = makeHost({
        settings: { enabled: false },
        front: (url) => (url.includes('cakeisalie') ? { ok: true, status: 200 } : { ok: false, status: 522 }),
    });
    const ctx = load(state);
    changeSetting(state, ctx, 'enabled', true);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'cakeisalie.co.uk' });
});

test('auto mode with nothing reachable refuses to write and turns the switch back off', () => {
    const state = makeHost({ settings: { enabled: false }, front: () => ({ ok: false, status: 0 }) });
    const ctx = load(state);
    changeSetting(state, ctx, 'enabled', true);
    assert.ok(!(CONFIG_PATH in state.files), 'a dead route reached the file');
    assert.strictEqual(state.settings.enabled, false);
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('Ни один CF-домен')));
});

test('choosing a zone probes only that zone and applies it', () => {
    const state = makeHost({
        settings: { enabled: false },
        front: () => ({ ok: false, status: 404 }),
    });
    const ctx = load(state);
    changeSetting(state, ctx, 'domain_index', 3);
    changeSetting(state, ctx, 'enabled', true);
    assert.deepStrictEqual(state.http.map((r) => r.url), ['https://kws2.cakeisalie.co.uk/']);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'cakeisalie.co.uk' });
});

test('a custom domain wins over the list and is normalised', () => {
    const state = makeHost({ settings: { enabled: false }, front: () => ({ ok: true, status: 200 }) });
    const ctx = load(state);
    changeSetting(state, ctx, 'custom_domain', '  Example.COM. ');
    changeSetting(state, ctx, 'enabled', true);
    assert.deepStrictEqual(state.http.map((r) => r.url), ['https://kws2.example.com/']);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'example.com' });
});

test('a custom domain that is not a hostname is refused', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    changeSetting(state, ctx, 'custom_domain', 'not a host/path');
    changeSetting(state, ctx, 'enabled', true);
    assert.ok(!(CONFIG_PATH in state.files));
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('имя хоста')));
});

test('the connect row applies a custom domain even when the probe gets nothing', () => {
    const state = makeHost({ settings: { enabled: false, custom_domain: 'mine.example' }, front: () => ({ ok: false, status: 0 }) });
    const ctx = load(state);
    clickKey(ctx, 'connect');
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'mine.example' });
    assert.strictEqual(state.settings.enabled, true);
    assert.ok(state.bulletins.some((b) => b.text.includes('не ответил')), JSON.stringify(state.bulletins));
});

test('switching off removes the document and says so', () => {
    const state = makeHost({
        settings: { enabled: true },
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }) },
        front: () => ({ ok: true, status: 200 }),
    });
    const ctx = load(state);
    assert.ok(CONFIG_PATH in state.files);
    changeSetting(state, ctx, 'enabled', false);
    assert.ok(!(CONFIG_PATH in state.files), 'the config survived');
    assert.ok(state.bulletins.some((b) => b.kind === 'info' && b.text.includes('Выключено')));
});

test('loading with an existing document probes nothing and mirrors it', () => {
    const state = makeHost({
        settings: {},
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'lovetrue.co.uk' }) },
    });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0);
    const controls = settingsOf(ctx);
    assert.strictEqual(controls.find((c) => c.key === 'enabled').value, true);
    assert.strictEqual(controls.find((c) => c.key === 'domain_index').value, 5);
    assert.strictEqual(controls.find((c) => c.key === 'custom_domain').value, '');
});

test('a document with a custom zone lands in the custom field', () => {
    const state = makeHost({
        settings: {},
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'my.zone.example' }) },
    });
    const ctx = load(state);
    assert.strictEqual(controlByKey(ctx, 'custom_domain').value, 'my.zone.example');
});

test('loading with the switch on and no document reconnects by itself', () => {
    const state = makeHost({
        settings: {},
        front: () => ({ ok: false, status: 404 }),
    });
    const ctx = load(state);
    assert.strictEqual(state.http.length, DOMAINS.length);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'pclead.co.uk' });
});

test('a remembered zone is restored without probing', () => {
    const state = makeHost({ settings: { enabled: true, last_domain: 'offshor.co.uk' } });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'offshor.co.uk' });
});

test('typing in the custom field does not probe per keystroke', () => {
    const state = makeHost({
        settings: { enabled: true },
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }) },
    });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0);
    changeSetting(state, ctx, 'custom_domain', 'm');
    changeSetting(state, ctx, 'custom_domain', 'mi');
    changeSetting(state, ctx, 'custom_domain', 'mine.example');
    assert.strictEqual(state.http.length, 0);
    assert.deepStrictEqual(configOf(state), { enabled: true, domain: 'pclead.co.uk' });
});

test('the status row shows what the client confirmed', () => {
    const at = Math.floor(new Date(2026, 10, 3, 14, 5, 0).getTime() / 1000);
    const state = makeHost({
        settings: {},
        files: {
            [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }),
            [STATUS_PATH]: JSON.stringify({ host: 'kws2.pclead.co.uk', dc: 2, at: at }),
        },
    });
    const ctx = load(state);
    const status = controlByKey(ctx, 'status');
    assert.ok(status.subtext.includes('kws1…5.pclead.co.uk'), status.subtext);
    assert.ok(status.subtext.includes('клиент применил в 14:05'), status.subtext);
});

test('a status for another zone is not reported as confirmation', () => {
    const at = Math.floor(Date.now() / 1000) - 10;
    const state = makeHost({
        settings: {},
        files: {
            [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }),
            [STATUS_PATH]: JSON.stringify({ host: 'kws2.lovetrue.co.uk', at: at }),
        },
    });
    const ctx = load(state);
    assert.ok(controlByKey(ctx, 'status').subtext.includes('ещё переключается'));
});

test('unloading the plugin removes the transport', () => {
    const state = makeHost({
        settings: {},
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }) },
    });
    const ctx = load(state);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.ok(!(CONFIG_PATH in state.files), 'the transport outlived the plugin');
});

test('probing asks for kws2 of every zone and counts any answer', () => {
    const state = makeHost({
        settings: { enabled: false },
        front: (url) => (url.includes('noskomnadzor') ? { ok: false, status: 0 } : { ok: false, status: 404 }),
    });
    const ctx = load(state);
    clickKey(ctx, 'check');
    assert.strictEqual(state.http.length, DOMAINS.length);
    assert.ok(state.bulletins.some((b) => b.text.includes('Ответили 4 из 5')), JSON.stringify(state.bulletins));
    assert.ok(!(CONFIG_PATH in state.files), 'a probe wrote the config');
});

test('the report carries the applied transport and the confirmed host', () => {
    const at = Math.floor(new Date(2026, 10, 3, 9, 30, 0).getTime() / 1000);
    const state = makeHost({
        settings: {},
        files: {
            [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'cakeisalie.co.uk' }),
            [STATUS_PATH]: JSON.stringify({ host: 'kws2.cakeisalie.co.uk', at: at }),
        },
    });
    const ctx = load(state);
    clickKey(ctx, 'report');
    const report = state.clipboard[state.clipboard.length - 1];
    assert.ok(report.includes('cakeisalie.co.uk'), report);
    assert.ok(report.includes('kws2.cakeisalie.co.uk в 09:30'), report);
    assert.ok(report.includes('Выбор: cakeisalie.co.uk'), report);
});

const failed = [];
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed.push(name);
        console.log('FAIL ' + name + ': ' + error.message);
    }
}
console.log(failed.length === 0 ? '\n' + tests.length + ' tests passed' : '\n' + failed.length + ' failed');
process.exit(failed.length === 0 ? 0 : 1);