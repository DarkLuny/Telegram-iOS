/*
 * Runs js/tg_ws_proxy.plugin through the real bootstrap against a fake __host,
 * with a fake Documents directory and a fake CloudFlare front.
 *
 * This is a behavioural test of the port, not of the bootstrap: it drives the
 * settings screen, the decode of tg-ws-proxy's zone list, the save that the
 * client build reads, the disable path and the probes, and asserts on what
 * reached the host.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'tg_ws_proxy.plugin'), 'utf8');

const CONFIG_PATH = '/documents/tg_ws_proxy.json';

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
        pending: {},
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
            state.pending.http = token;
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

function clickRow(ctx, text) {
    const control = settingsOf(ctx).find((c) => c.type === 'text' && c.text === text);
    assert.ok(control, 'no Text row labelled ' + text);
    ctx.__extera.invokeSettingCallback(control.key, 'click', 'null');
    return control;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the plugin file', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 'tg_ws_proxy');
    assert.strictEqual(ctx.__name__, 'TG WS Proxy');
    assert.strictEqual(ctx.__version__, '2.0.0');
});

test('tg-ws-proxy zone list decodes to the five co.uk zones', () => {
    const state = makeHost();
    const ctx = load(state);
    const decoded = vm.runInContext('defaultCfproxyDomains()', ctx);
    assert.deepStrictEqual(Array.from(decoded), DOMAINS);
    assert.ok(decoded.every((d) => d.endsWith('.co.uk')));
});

test('the screen offers the switch, the zone selector and the apply row', () => {
    const state = makeHost();
    const ctx = load(state);
    const controls = settingsOf(ctx);
    const enable = controls.find((c) => c.type === 'switch' && c.key === 'enabled');
    assert.ok(enable, 'no enabled switch');
    assert.strictEqual(enable.value, false);
    const selector = controls.find((c) => c.type === 'selector' && c.key === 'domain_index');
    assert.ok(selector, 'no domain selector');
    assert.deepStrictEqual(Array.from(selector.items), DOMAINS.concat(['Свой домен…']));
    const input = controls.find((c) => c.type === 'input' && c.key === 'custom_domain');
    assert.ok(input, 'no custom domain input');
    assert.ok(controls.some((c) => c.type === 'text' && c.text === 'Применить'));
    // No transport-specific state is invented before the client has any.
    assert.ok(!(CONFIG_PATH in state.files));
});

test('applying writes the document the client build reads', () => {
    const state = makeHost({ settings: { enabled: true, domain_index: 1 } });
    const ctx = load(state);
    clickRow(ctx, 'Применить');
    const written = state.files[CONFIG_PATH];
    assert.ok(written, 'no config written');
    assert.deepStrictEqual(JSON.parse(written), { enabled: true, domain: 'offshor.co.uk' });
    assert.ok(state.bulletins.some((b) => b.kind === 'success' && b.text.includes('перезапуска')));
    // The row reflects the file without the test rebuilding it by hand.
    const status = settingsOf(ctx).find((c) => c.type === 'text' && c.key === 'status');
    assert.ok(status.subtext.includes('Включено'), status.subtext);
    assert.ok(status.subtext.includes('offshor.co.uk'), status.subtext);
});

test('a custom domain wins and is normalised', () => {
    const state = makeHost({ settings: { enabled: true, domain_index: 0, custom_domain: '  Example.COM. ' } });
    const ctx = load(state);
    clickRow(ctx, 'Применить');
    assert.deepStrictEqual(JSON.parse(state.files[CONFIG_PATH]), { enabled: true, domain: 'example.com' });
});

test('a domain that is not a hostname is refused', () => {
    const state = makeHost({ settings: { enabled: true, custom_domain: 'not a host/path' } });
    const ctx = load(state);
    clickRow(ctx, 'Применить');
    assert.ok(!(CONFIG_PATH in state.files), 'a bad domain reached the file');
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('имя хоста')));
});

test('the custom entry with an empty field is refused, not sent to the first zone', () => {
    const state = makeHost({ settings: { enabled: true, domain_index: DOMAINS.length } });
    const ctx = load(state);
    clickRow(ctx, 'Применить');
    assert.ok(!(CONFIG_PATH in state.files), 'an unfinished custom choice reached the file');
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('не задан')));
});

test('probing with the custom entry and no field asks for a domain', () => {
    const state = makeHost({ settings: { domain_index: DOMAINS.length } });
    const ctx = load(state);
    clickRow(ctx, 'Проверить CF-домены');
    assert.strictEqual(state.http.length, 0);
    assert.ok(state.bulletins.some((b) => b.kind === 'error' && b.text.includes('Укажите свой домен')));
});

test('disabling removes the document and turns the switch off', () => {
    const state = makeHost({
        settings: { enabled: true, domain_index: 0 },
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'pclead.co.uk' }) },
    });
    const ctx = load(state);
    assert.ok(CONFIG_PATH in state.files);
    clickRow(ctx, 'Отключить и удалить настройку');
    assert.ok(!(CONFIG_PATH in state.files), 'the config survived');
    assert.strictEqual(state.settings.enabled, false);
    const enable = settingsOf(ctx).find((c) => c.type === 'switch' && c.key === 'enabled');
    assert.strictEqual(enable.value, false);
});

test('the screen mirrors an existing document on load', () => {
    const state = makeHost({
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'lovetrue.co.uk' }) },
    });
    const ctx = load(state);
    const controls = settingsOf(ctx);
    assert.strictEqual(controls.find((c) => c.key === 'enabled').value, true);
    assert.strictEqual(controls.find((c) => c.key === 'domain_index').value, 4);
    assert.strictEqual(controls.find((c) => c.key === 'custom_domain').value, '');
});

test('a document with a custom zone lands in the custom field', () => {
    const state = makeHost({
        files: { [CONFIG_PATH]: JSON.stringify({ enabled: true, domain: 'my.zone.example' }) },
    });
    const ctx = load(state);
    const controls = settingsOf(ctx);
    assert.strictEqual(controls.find((c) => c.key === 'custom_domain').value, 'my.zone.example');
});

test('probes ask for kws2 of every zone and count any answer', () => {
    const state = makeHost({
        // kws2's plain GET has no Upgrade header, so the front answers 404 —
        // that is still proof that DNS and TLS work.
        front: (url) => (url.includes('noskomnadzor')
            ? { ok: false, status: 0, error: 'timeout' }
            : { ok: false, status: 404, text: '' }),
    });
    const ctx = load(state);
    clickRow(ctx, 'Проверить CF-домены');
    assert.strictEqual(state.http.length, DOMAINS.length);
    assert.deepStrictEqual(
        state.http.map((r) => r.url),
        DOMAINS.map((d) => 'https://kws2.' + d + '/')
    );
    assert.ok(state.http.every((r) => r.timeout === 6));
    assert.ok(state.bulletins.some((b) => b.text.includes('Ответили 4 из 5')), JSON.stringify(state.bulletins));
});

test('the probe follows the custom domain instead of the list', () => {
    const state = makeHost({ settings: { custom_domain: 'mine.example' }, front: () => ({ ok: true, status: 200 }) });
    const ctx = load(state);
    clickRow(ctx, 'Проверить CF-домены');
    assert.deepStrictEqual(state.http.map((r) => r.url), ['https://kws2.mine.example/']);
});

test('the report carries the applied transport and the zones', () => {
    const state = makeHost({ settings: { enabled: true, domain_index: 2 } });
    const ctx = load(state);
    clickRow(ctx, 'Применить');
    clickRow(ctx, 'Собрать отчёт');
    const report = state.clipboard[state.clipboard.length - 1];
    assert.ok(report.includes('cakeisalie.co.uk'), report);
    assert.ok(report.includes('выключен') === false, report);
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