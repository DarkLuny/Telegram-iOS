/*
 * Runs js/tg_ws_proxy.plugin through the real bootstrap against a fake __host.
 *
 * The behaviour under test is the automatic one, the reference app minus its
 * button: loading with the switch on (or turning it on) picks a CloudFlare zone
 * by itself, asks the client to run its local MTProxy for that zone, and reports
 * exactly what the client answered. The native side is faked with the same
 * request JSON and response shape PluginLocalProxy uses, so the plugin is
 * checked against the real contract rather than a mock of its own invention.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'tg_ws_proxy.plugin'), 'utf8');

const LEGACY_PATH = '/documents/tg_ws_proxy.json';

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
    const proxyStatus = {
        ok: true,
        running: false,
        host: '127.0.0.1',
        port: 1443,
        domain: '',
        active: false,
        connections: 0,
        upstreams: 0,
        link: '',
    };
    const state = {
        calls,
        settings,
        files: Object.assign({}, options.files || {}),
        bulletins: [],
        http: [],
        clipboard: [],
        opened: [],
        scheduled: [],
        proxy: {
            status: proxyStatus,
            requests: [],
            starts: [],
            stops: 0,
        },
        supported: options.supported !== false,
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
        schedulePlugin: (id, delay, token) => { state.scheduled.push({ id, delay, token }); },
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

    if (state.supported) {
        // The synchronous read a settings row uses.
        host.localProxyStatus = () => JSON.stringify(Object.assign({}, proxyStatus));
        // The asynchronous request: `{action, domain}` in, `{ok, status}` out,
        // resolved through the token the bootstrap handed out.
        host.localProxy = (id, requestJSON, token) => {
            const request = JSON.parse(requestJSON || '{}');
            state.proxy.requests.push(request);
            let response;
            if (request.action === 'start') {
                if (options.startFails) {
                    Object.assign(proxyStatus, {
                        ok: false, running: false, domain: '', active: false, connections: 0, upstreams: 0,
                        error: 'address already in use',
                    });
                    response = { ok: false, error: 'address already in use', status: Object.assign({}, proxyStatus) };
                } else {
                    Object.assign(proxyStatus, {
                        ok: true,
                        running: true,
                        host: '127.0.0.1',
                        port: options.port || 1443,
                        domain: request.domain,
                        active: options.startActive !== false,
                        connections: options.connections || 0,
                        upstreams: options.upstreams || 0,
                        link: 'tg://proxy?server=127.0.0.1&port=' + (options.port || 1443) + '&secret=dd' + '00',
                        error: undefined,
                    });
                    delete proxyStatus.error;
                    state.proxy.starts.push(request.domain);
                    response = { ok: true, status: Object.assign({}, proxyStatus) };
                }
            } else if (request.action === 'stop') {
                Object.assign(proxyStatus, {
                    running: false, domain: '', active: false, connections: 0, upstreams: 0, link: '',
                });
                state.proxy.stops += 1;
                response = { ok: true, status: Object.assign({}, proxyStatus) };
            } else {
                response = { ok: true, status: Object.assign({}, proxyStatus) };
            }
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' +
                    JSON.stringify(JSON.stringify(response)) + ')',
                state.context
            );
        };
    }

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

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the plugin file', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 'tg_ws_proxy');
    assert.strictEqual(ctx.__name__, 'TG WS Proxy');
    assert.strictEqual(ctx.__version__, '3.0.0');
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
    const selector = controls.find((c) => c.type === 'selector' && c.key === 'zone_index');
    assert.ok(selector, 'no domain selector');
    assert.deepStrictEqual(Array.from(selector.items), ['Автоматически'].concat(DOMAINS));
    assert.ok(controls.some((c) => c.key === 'connect' && c.type === 'text'));
    assert.ok(controls.some((c) => c.key === 'status' && c.type === 'text'));
    assert.ok(!controls.some((c) => c.type === 'text' && c.text === 'Применить'));
    assert.strictEqual(state.proxy.requests.length, 0, 'a disabled plugin started the proxy');
});

test('enabling connects by itself: probes every zone, starts the proxy on the first that answers', () => {
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
    assert.deepStrictEqual(state.proxy.starts, ['offshor.co.uk']);
    assert.strictEqual(state.settings.last_domain, 'offshor.co.uk');
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('offshor.co.uk')), JSON.stringify(state.bulletins));
    // The client connects a moment after the entry becomes active; one refresh
    // is asked for so the row can show the live counters.
    assert.ok(state.scheduled.some((s) => s.delay === 3000), JSON.stringify(state.scheduled));
});

test('a five-hundred answer from the edge is not a working zone', () => {
    const state = makeHost({
        settings: { enabled: false },
        front: (url) => (url.includes('cakeisalie') ? { ok: true, status: 200 } : { ok: false, status: 522 }),
    });
    const ctx = load(state);
    changeSetting(state, ctx, 'enabled', true);
    assert.deepStrictEqual(state.proxy.starts, ['cakeisalie.co.uk']);
});

test('nothing reachable still starts the proxy on the fallback route', () => {
    const state = makeHost({ settings: { enabled: false }, front: () => ({ ok: false, status: 0 }) });
    const ctx = load(state);
    changeSetting(state, ctx, 'enabled', true);
    // The listener has its own fallbacks (Telegram's web front, then the
    // datacenter address), so a failed probe must not leave the user without a
    // transport — but the user is told the zone went unchecked.
    assert.deepStrictEqual(state.proxy.starts, ['pclead.co.uk']);
    assert.strictEqual(state.settings.enabled, true, 'the switch was turned off');
    assert.ok(state.bulletins.some((b) => b.kind === 'info' && b.text.includes('не ответил')), JSON.stringify(state.bulletins));
    assert.ok(!state.bulletins.some((b) => b.kind === 'success'), JSON.stringify(state.bulletins));
});

test('the status row reads the host: entry active and live counters', () => {
    const state = makeHost({
        settings: { enabled: true, last_domain: 'offshor.co.uk' },
        connections: 2,
        upstreams: 2,
    });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0, 'a remembered zone was probed again');
    assert.deepStrictEqual(state.proxy.starts, ['offshor.co.uk']);
    const status = controlByKey(ctx, 'status');
    assert.ok(status.subtext.includes('127.0.0.1:1443'), status.subtext);
    assert.ok(status.subtext.includes('kws1…5.offshor.co.uk'), status.subtext);
    assert.ok(status.subtext.includes('соединений: 2'), status.subtext);
    assert.ok(status.subtext.includes('каналов: 2'), status.subtext);
});

test('a running proxy whose entry is not active is reported as such', () => {
    const state = makeHost({
        settings: { enabled: true, last_domain: 'pclead.co.uk' },
        startActive: false,
    });
    const ctx = load(state);
    assert.ok(controlByKey(ctx, 'status').subtext.includes('не активна'));
});

test('choosing a zone starts it at once, without a probe', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    changeSetting(state, ctx, 'zone_index', 3);
    assert.strictEqual(state.proxy.starts.length, 0, 'a stopped plugin started something');
    changeSetting(state, ctx, 'enabled', true);
    assert.strictEqual(state.http.length, 0, 'an explicit zone was probed');
    assert.deepStrictEqual(state.proxy.starts, ['cakeisalie.co.uk']);
});

test('a custom domain wins over the list and is normalised', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    changeSetting(state, ctx, 'custom_domain', '  Example.COM. ');
    changeSetting(state, ctx, 'enabled', true);
    assert.deepStrictEqual(state.proxy.starts, ['example.com']);
});

test('a custom domain that is not a hostname is refused', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    changeSetting(state, ctx, 'custom_domain', 'not a host/path');
    changeSetting(state, ctx, 'enabled', true);
    assert.strictEqual(state.proxy.starts.length, 0, 'an invalid domain reached the proxy');
    assert.strictEqual(state.settings.enabled, false);
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('имя хоста')));
});

test('the connect row starts a custom domain without a probe', () => {
    const state = makeHost({ settings: { enabled: false, custom_domain: 'mine.example' } });
    const ctx = load(state);
    clickKey(ctx, 'connect');
    assert.deepStrictEqual(state.proxy.starts, ['mine.example']);
    assert.strictEqual(state.settings.enabled, true);
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('mine.example')), JSON.stringify(state.bulletins));
});

test('switching off stops the host proxy and returns to the direct route', () => {
    const state = makeHost({ settings: { enabled: true, last_domain: 'pclead.co.uk' } });
    const ctx = load(state);
    assert.strictEqual(state.proxy.starts.length, 1);
    changeSetting(state, ctx, 'enabled', false);
    assert.strictEqual(state.proxy.stops, 1);
    assert.ok(state.bulletins.some((b) => b.kind === 'info' && b.text.includes('Выключено')));
});

test('an unsupported client build is reported, not faked', () => {
    const state = makeHost({ settings: {}, supported: false });
    const ctx = load(state);
    assert.ok(controlByKey(ctx, 'status').subtext.includes('не умеет локальный прокси'));
    assert.strictEqual(state.proxy.starts.length, 0);
    assert.ok(!state.bulletins.some((b) => b.kind === 'success'));
});

test('a host failure turns the switch off instead of claiming success', () => {
    const state = makeHost({ settings: { enabled: false }, startFails: true });
    const ctx = load(state);
    changeSetting(state, ctx, 'enabled', true);
    assert.strictEqual(state.settings.enabled, false);
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('address already in use')), JSON.stringify(state.bulletins));
});

test('loading with the switch on and a remembered zone starts without probing', () => {
    const state = makeHost({ settings: { enabled: true, last_domain: 'offshor.co.uk' } });
    const ctx = load(state);
    assert.strictEqual(state.http.length, 0);
    assert.deepStrictEqual(state.proxy.starts, ['offshor.co.uk']);
    // An automatic choice stays automatic, so a later enable may pick again.
    assert.strictEqual(controlByKey(ctx, 'zone_index').value, 0);
    assert.strictEqual(controlByKey(ctx, 'custom_domain').value, '');
});

test('loading with the switch on and no remembered zone chooses automatically', () => {
    const state = makeHost({ settings: {}, front: () => ({ ok: false, status: 404 }) });
    const ctx = load(state);
    assert.strictEqual(state.http.length, DOMAINS.length);
    assert.deepStrictEqual(state.proxy.starts, ['pclead.co.uk']);
});

test('typing in the custom field does nothing until applied', () => {
    const state = makeHost({ settings: { enabled: true, last_domain: 'pclead.co.uk' } });
    const ctx = load(state);
    assert.strictEqual(state.proxy.starts.length, 1);
    changeSetting(state, ctx, 'custom_domain', 'm');
    changeSetting(state, ctx, 'custom_domain', 'mi');
    changeSetting(state, ctx, 'custom_domain', 'mine.example');
    assert.strictEqual(state.http.length, 0);
    assert.deepStrictEqual(state.proxy.starts, ['pclead.co.uk']);
});

test('unloading the plugin stops the proxy', () => {
    const state = makeHost({ settings: { enabled: true, last_domain: 'pclead.co.uk' } });
    const ctx = load(state);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.strictEqual(state.proxy.stops, 1, 'the tunnel outlived the plugin');
});

test('the legacy document from 2.x is removed on load', () => {
    const state = makeHost({
        settings: { enabled: false },
        files: { [LEGACY_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }) },
    });
    load(state);
    assert.ok(!(LEGACY_PATH in state.files), 'the old web-route document survived');
    assert.ok(!Object.keys(state.files).some((p) => p.includes('tg_ws_proxy.json')),
        'the plugin wrote a document the client no longer reads');
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
    assert.strictEqual(state.proxy.starts.length, 0, 'a probe started the proxy');
});

test('the report carries the listening proxy and the counters', () => {
    const state = makeHost({
        settings: { enabled: true, last_domain: 'cakeisalie.co.uk' },
        connections: 3,
        upstreams: 3,
    });
    const ctx = load(state);
    clickKey(ctx, 'report');
    const report = state.clipboard[state.clipboard.length - 1];
    assert.ok(report.includes('MTProxy 127.0.0.1:1443'), report);
    assert.ok(report.includes('kws1…5.cakeisalie.co.uk'), report);
    assert.ok(report.includes('Запись в списке: активна'), report);
    assert.ok(report.includes('Соединения: 3, каналы: 3'), report);
    assert.ok(report.includes('Выбор: автоматически'), report);
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