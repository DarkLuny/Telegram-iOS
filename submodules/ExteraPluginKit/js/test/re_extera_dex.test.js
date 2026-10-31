/*
 * Runs js/re_extera_dex.plugin through the real bootstrap against a fake __host,
 * with a fake `actual.json`.
 *
 * The plugin exists on Android to load a Dalvik module, which cannot happen here.
 * What this test pins down is the half that does work and the honesty of the
 * other half: the version lookup picks the same entry the Python did, the settings
 * row reports it, and nothing claims to have started or downloaded a dex.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 're_extera_dex.plugin'), 'utf8');

const APP_VERSION = '13.1.1';
const URL_COUNT = [0];

const VERSIONS = {
    '12.2.3': { code: 13020, link: 'https://example.invalid/re-12.2.3.dex' },
    '12.9.0': { code: 13090, link: 'https://example.invalid/re-12.9.0.dex' },
    '13.1.1': { code: 13110, link: 'https://example.invalid/re-13.1.1.dex' },
    '13.2.0': { code: 13120, link: 'https://example.invalid/re-13.2.0.dex' },
};

function makeIntl(locale) {
    // The plugin calls `Intl.DateTimeFormat()` without `new`, the way the SDK's
    // `Locale.getDefault()` reads a locale. A constructor-only fake would fall
    // into the plugin's `catch` and always answer English.
    function DateTimeFormat() {
        if (!(this instanceof DateTimeFormat)) {
            return new DateTimeFormat();
        }
        this.resolvedOptions = () => ({ locale: locale || 'en-US' });
    }
    return { DateTimeFormat: DateTimeFormat };
}

function makeHost(options) {
    options = options || {};
    const calls = [];
    const settings = Object.assign({}, options.settings || {});
    const state = {
        calls,
        settings,
        bulletins: [],
        files: options.files || {},
        actual: options.actual === undefined ? VERSIONS : options.actual,
        actualStatus: options.actualStatus || 200,
        appVersion: options.appVersion === undefined ? APP_VERSION : options.appVersion,
    };

    state.host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: (id, key) => (key in settings ? settings[key] : null),
        setSetting: (id, key, value) => { settings[key] = value; return true; },
        exportSettings: () => ({ ...settings }),
        importSettings: (id, values) => { Object.assign(settings, values); },
        addHook: () => {},
        addOnSendMessageHook: () => {},
        addMenuItem: () => 'item',
        removeMenuItem: () => {},
        sendText: () => {},
        sendFile: () => {},
        editMessage: () => {},
        showBulletin: (id, kind, text) => {
            let payload;
            try { payload = JSON.parse(text); } catch (error) { payload = { kind, text }; }
            state.bulletins.push({ kind: payload.kind || kind, text: payload.text, raw: payload });
        },
        showAlert: () => {},
        dismissAlert: () => {},
        fileOp: (id, op, p, payload) => {
            calls.push(['fileOp', id, op, p, payload]);
            if (op === 'ensure_dir' || op === 'write_text' || op === 'write_bytes') {
                return 'true';
            }
            if (op === 'exists') {
                return JSON.stringify(Object.prototype.hasOwnProperty.call(state.files, p));
            }
            if (op === 'read_bytes') {
                return JSON.stringify(state.files[p] === undefined ? null : state.files[p]);
            }
            if (op === 'cache_dir' || op === 'files_dir' || op === 'documents_dir') {
                return JSON.stringify('/files');
            }
            return 'null';
        },
        selectedAccount: () => 0,
        appVersion: () => state.appVersion,
        pluginDirectory: () => '/plugins/re_extera_dex',
        schedulePlugin: () => {},
        openUrl: () => true,
        themeColors: () => '{}',
        // The one network call the plugin makes. `actualStatus` other than 200
        // answers the way PluginHttpAccess does for a failing request.
        httpGet: (id, url, headers, timeout, token) => {
            URL_COUNT[0] += 1;
            calls.push(['httpGet', id, url, timeout]);
            if (state.actualStatus !== 200) {
                vm.runInContext(
                    '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: false, status: state.actualStatus, error: 'HTTP ' + state.actualStatus })) + ')',
                    state.context
                );
                return;
            }
            vm.runInContext(
                '__extera.resolveBridge(' + JSON.stringify(token) + ', ' + JSON.stringify(JSON.stringify({ ok: true, status: 200, text: JSON.stringify(state.actual), headers: {} })) + ')',
                state.context
            );
        },
        proxyList: () => {},
        proxyAdd: () => {},
        proxyRemoveAll: () => {},
        ownPeerId: () => {},
    };
    return state;
}

function load(state, locale) {
    const context = vm.createContext({ __host: state.host, console, Intl: makeIntl(locale) });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('re_extera_dex', 're:extera v2');
    vm.runInContext(plugin, context, { filename: 're_extera_dex.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

function clickSettingsRow(ctx) {
    const row = settingsOf(ctx).find((c) => c.type === 'text');
    assert.ok(row, 'no settings row');
    ctx.__extera.invokeSettingCallback(row.key, 'click', 'null');
}

function logText(state) {
    return state.calls.filter((c) => c[0] === 'log').map((c) => String(c[2])).join('\n');
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 're_extera_dex');
    assert.strictEqual(ctx.__name__, 're:extera v2');
    assert.strictEqual(ctx.__version__, '2.4.0');
    assert.strictEqual(ctx.__min_version__, '12.2.3');
    assert.deepStrictEqual(Array.from(ctx.__category__), ['privacy', 'chats']);
    assert.strictEqual(ctx.__author__.indexOf('@shiawasez'), 0);
});

test('the upstream constants are unchanged', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.strictEqual(ctx.DEFAULT_URL,
        'https://github.com/logopek/re-extera-pub/raw/refs/heads/main/re-extera.1.3.dex');
    assert.strictEqual(ctx.VERSION_URL,
        'https://github.com/logopek/re-extera-pub/raw/refs/heads/main/actual.json');
    assert.strictEqual(ctx.CLASS_NAME, 'ni.shikatu.re_extera.Main');
    assert.strictEqual(ctx.METHOD_NAME, 'start');
});

test('an exact build match is preferred over any fallback', () => {
    const state = makeHost();
    const ctx = load(state);
    let answered = null;
    ctx.__extera.instance.loader.fetch_version_info((info) => { answered = info; });
    assert.ok(answered, 'the lookup answered');
    assert.strictEqual(answered.key, APP_VERSION);
    assert.strictEqual(answered.code, 13110);
    assert.strictEqual(answered.exact, true);
    assert.strictEqual(answered.link, 'https://example.invalid/re-13.1.1.dex');
});

test('a build with no entry falls back to the newest one at or below it', () => {
    const state = makeHost({ appVersion: '13.1.5' });
    const ctx = load(state);
    let answered = null;
    ctx.__extera.instance.loader.fetch_version_info((info) => { answered = info; });
    assert.ok(answered, 'the lookup answered');
    // 13.2.0 is newer and must not win; 13.1.1 is the closest below.
    assert.strictEqual(answered.key, '13.1.1');
    assert.strictEqual(answered.code, 13110);
    assert.strictEqual(answered.exact, false);
});

test('a build older than every entry has no answer at all', () => {
    const state = makeHost({ appVersion: '11.0.0' });
    const ctx = load(state);
    let answered = 'unset';
    ctx.__extera.instance.loader.fetch_version_info((info) => { answered = info; });
    assert.strictEqual(answered, null);
    assert.ok(logText(state).includes('No suitable version found in actual.json'), logText(state));
});

test('a version key that is not numeric is skipped, as Python did', () => {
    const state = makeHost({
        appVersion: '13.1.5',
        actual: {
            '12.2.3': { code: 13020, link: 'a' },
            'nightly': { code: 99999, link: 'b' },
            '13.1.1': { code: 13110, link: 'c' },
        },
    });
    const ctx = load(state);
    let answered = null;
    ctx.__extera.instance.loader.fetch_version_info((info) => { answered = info; });
    assert.ok(answered);
    assert.strictEqual(answered.key, '13.1.1');
});

test('a failing version list reports the transport error, not a crash', () => {
    const state = makeHost({ actualStatus: 500 });
    const ctx = load(state);
    let answered = 'unset';
    let error = 'unset';
    ctx.__extera.instance.loader.fetch_version_info((info, detail) => {
        answered = info;
        error = detail;
    });
    assert.strictEqual(answered, null);
    assert.strictEqual(error, 'HTTP 500');
    assert.ok(logText(state).includes('Error fetching version info'));
});

test('the settings row is one text row with a translated label', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    const rows = settingsOf(ctx);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].type, 'text');
    assert.strictEqual(rows[0].key, 'open_settings');
    assert.strictEqual(rows[0].text, 're:extera Settings');

    const ru = makeHost();
    const ruCtx = load(ru, 'ru-RU');
    assert.strictEqual(settingsOf(ruCtx)[0].text, 'Настройки re:extera');
});

test('a tap on the row reports the matching build, which the module itself cannot show', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    clickSettingsRow(ctx);
    const texts = state.bulletins.map((b) => b.text).join(' | ');
    assert.ok(state.bulletins.some((b) => b.kind === 'info' && b.text.includes('Checking')));
    assert.ok(texts.includes('13.1.1'), texts);
    assert.ok(texts.includes('13110'), texts);
});

test('a tap on the row with no build for this version says so instead of linking', () => {
    const state = makeHost({ appVersion: '11.0.0' });
    const ctx = load(state, 'en-US');
    clickSettingsRow(ctx);
    const texts = state.bulletins.map((b) => b.text).join(' | ');
    assert.ok(texts.includes('11.0.0'), texts);
    assert.ok(texts.includes('no build'), texts);
});

test('loading never downloads the dex and says why once', () => {
    const state = makeHost();
    const ctx = load(state);
    // The only request the plugin makes is the version list.
    const requests = state.calls.filter((c) => c[0] === 'httpGet');
    assert.strictEqual(requests.length, 1, JSON.stringify(requests));
    assert.ok(requests[0][2].endsWith('actual.json'), requests[0][2]);
    const writes = state.calls.filter((c) => c[0] === 'fileOp' && (c[2] === 'write_bytes' || c[2] === 'write_text'));
    assert.deepStrictEqual(writes, [], 'no cache file is written');
    const text = logText(state);
    assert.ok(text.includes('needs Dalvik'), text);
    assert.ok(text.includes('Not downloading'), text);
});

test('a cache copied from Android is reported by size and not executed', () => {
    // 8 base64 characters encode 5 bytes after the padding is removed.
    const state = makeHost({ files: { '/plugins/re_extera_dex/re_extera_cache/cached.dat': 'YWJjZGU=' } });
    const ctx = load(state);
    const text = logText(state);
    assert.ok(text.includes('cached.dat'), text);
    assert.ok(text.includes('5'), text);
    assert.ok(text.includes('cannot execute dex'), text);
});

test('start_from_bytes and show_settings answer without pretending', () => {
    const state = makeHost();
    const ctx = load(state);
    const loader = ctx.__extera.instance.loader;
    assert.strictEqual(loader.start_from_bytes('AAAA'), false);
    assert.strictEqual(loader.show_settings(), false);
    assert.strictEqual(loader.unload(), true);
    const text = logText(state);
    assert.ok(text.includes('ni.shikatu.re_extera.Main'), text);
    assert.ok(text.includes('no Dalvik on iOS'), text);
});

test('an unknown app version is reported instead of guessed', () => {
    const state = makeHost({ appVersion: 'Unknown' });
    const ctx = load(state, 'en-US');
    clickSettingsRow(ctx);
    const texts = state.bulletins.map((b) => b.text).join(' | ');
    assert.ok(texts.includes('unknown'), texts);
});

test('unloading stops the loader and logs it', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.ok(logText(state).includes('re:extera: plugin unloaded'));
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
console.log(failed === 0 ? `\n${tests.length}/${tests.length} passed` : `\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed === 0 ? 0 : 1);