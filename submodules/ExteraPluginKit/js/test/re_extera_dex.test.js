/*
 * Runs js/re_extera_dex.plugin through the real bootstrap against a fake __host,
 * with a fake `actual.json`.
 *
 * The Android plugin loads a Dalvik module and that module contains the actual
 * features. What this test pins down is the part of that module which can be
 * expressed as client hooks — ghost mode — plus the honesty of the rest: the
 * version lookup still answers, nothing is downloaded, and no switch exists that
 * cannot do what it says.
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
        alerts: [],
        files: options.files || {},
        written: [],
        store: options.store || {},
        failStore: !!options.failStore,
        actual: options.actual === undefined ? VERSIONS : options.actual,
        actualStatus: options.actualStatus || 200,
        appVersion: options.appVersion === undefined ? APP_VERSION : options.appVersion,
    };
    const storePath = '/plugins/re_extera_dex/re_extera_store/store.json';
    if (Object.keys(state.store).length > 0) {
        state.files[storePath] = JSON.stringify(state.store);
    }

    state.host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: (id, key) => (key in settings ? settings[key] : null),
        setSetting: (id, key, value) => { settings[key] = value; return true; },
        exportSettings: () => ({ ...settings }),
        importSettings: (id, values) => { Object.assign(settings, values); },
        addHook: (id, name, sub) => calls.push(['addHook', id, name, sub]),
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
        showAlert: (id, json) => {
            state.alerts.push(JSON.parse(json));
        },
        dismissAlert: () => {},
        fileOp: (id, op, p, payload) => {
            calls.push(['fileOp', id, op, p, payload]);
            if (op === 'ensure_dir') {
                return 'true';
            }
            if (op === 'write_text' || op === 'write_bytes') {
                if (state.failStore) {
                    return 'false';
                }
                if (op === 'write_text') {
                    state.written.push(payload);
                    state.files[p] = payload;
                }
                return 'true';
            }
            if (op === 'exists') {
                if (state.failStore) {
                    return 'false';
                }
                return JSON.stringify(Object.prototype.hasOwnProperty.call(state.files, p));
            }
            if (op === 'read_text') {
                if (state.failStore) {
                    return 'null';
                }
                return JSON.stringify(state.files[p] === undefined ? null : state.files[p]);
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

// Runs one request hook the way the runtime does: payload plus the context that
// carries both spellings of the name.
function hookOf(ctx, name) {
    return JSON.parse(ctx.__extera.runHook(
        'pre_request_hook',
        JSON.stringify({ peer: 'inputPeerUser', action: 'sendMessageTypingAction' }),
        JSON.stringify({ name: name, tlName: 'TL_' + name.replace(/\./g, '_'), account: 900, field: 'request' })
    ));
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

test('the settings screen is ghost mode, with one switch per thing it blocks', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    const rows = settingsOf(ctx);
    const switches = rows.filter((r) => r.type === 'switch');
    const keys = switches.map((r) => r.key);
    // Ghost mode's own switches come first; the history and hiding sections the
    // module also shipped follow them.
    assert.deepStrictEqual(keys.slice(0, 6), [
        're_extera_ghost',
        're_extera_ghost_typing',
        're_extera_ghost_online',
        're_extera_ghost_read',
        're_extera_ghost_read_contents',
        're_extera_ghost_stories',
    ]);
    assert.deepStrictEqual(keys.slice(6), [
        're_extera_save_deleted_messages',
        're_extera_save_manually_deleted',
        're_extera_save_edits',
        're_extera_shadowban',
        're_extera_filters_enabled',
    ]);
    // No dead rows: every switch has a handler the host can call.
    for (const row of switches) {
        assert.strictEqual(row.has_callbacks, true, row.key);
    }
    // Ghost mode itself ships off; its parts ship on, so enabling the master
    // switch covers everything the module covered. The two ways of keeping a
    // deleted message and both hiding switches ship off: they store or hide
    // data, which is not what a fresh install expects.
    assert.strictEqual(switches[0].value, false);
    for (const row of switches.slice(1, 6)) {
        assert.strictEqual(row.value, true, row.key);
    }
    assert.strictEqual(switches[6].value, false);
    assert.strictEqual(switches[7].value, false);
    assert.strictEqual(switches[8].value, true);

    const ru = makeHost();
    const ruCtx = load(ru, 'ru-RU');
    assert.strictEqual(settingsOf(ruCtx).filter((r) => r.type === 'switch')[0].text, 'Режим призрака');
});

test('with ghost mode off nothing is cancelled', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    for (const name of ['messages.setTyping', 'account.updateStatus', 'messages.readHistory', 'stories.readStories']) {
        assert.strictEqual(hookOf(ctx, name).strategy, 'default', name);
    }
});

test('ghost mode cancels typing, online, read and story requests', () => {
    const state = makeHost({ settings: { re_extera_ghost: true } });
    const ctx = load(state, 'en-US');
    const cancelled = [
        'messages.setTyping',
        'messages.setEncryptedTyping',
        'account.updateStatus',
        'messages.readHistory',
        'channels.readHistory',
        'messages.readMessageContents',
        'channels.readMessageContents',
        'stories.readStories',
    ];
    for (const name of cancelled) {
        assert.strictEqual(hookOf(ctx, name).strategy, 'cancel', name);
    }
    // The TL spelling the runtime actually passes is understood too.
    assert.strictEqual(
        ctx.__extera.runHook('pre_request_hook', '{}', JSON.stringify({ tlName: 'TL_messages_setTyping', name: 'messages.setTyping', account: 900, field: 'request' })),
        '{"strategy":"cancel"}'
    );
    // And an unrelated request passes through untouched.
    assert.strictEqual(hookOf(ctx, 'messages.sendMessage').strategy, 'default');
});

test('each part of ghost mode can be turned off on its own', () => {
    const state = makeHost({
        settings: {
            re_extera_ghost: true,
            re_extera_ghost_typing: false,
            re_extera_ghost_stories: false,
        },
    });
    const ctx = load(state, 'en-US');
    assert.strictEqual(hookOf(ctx, 'messages.setTyping').strategy, 'default');
    assert.strictEqual(hookOf(ctx, 'stories.readStories').strategy, 'default');
    // The parts that were left on still fire.
    assert.strictEqual(hookOf(ctx, 'account.updateStatus').strategy, 'cancel');
    assert.strictEqual(hookOf(ctx, 'messages.readHistory').strategy, 'cancel');
});

test('ghost mode lets the client go offline even though it blocks going online', () => {
    const state = makeHost({ settings: { re_extera_ghost: true } });
    const ctx = load(state, 'en-US');
    const online = JSON.parse(ctx.__extera.runHook(
        'pre_request_hook',
        JSON.stringify({ offline: false }),
        JSON.stringify({ name: 'account.updateStatus', tlName: 'TL_account_updateStatus', account: 900, field: 'request' })
    ));
    assert.strictEqual(online.strategy, 'cancel');
    // The other direction is the client leaving; suppressing it would strand the
    // account as permanently online.
    const offline = JSON.parse(ctx.__extera.runHook(
        'pre_request_hook',
        JSON.stringify({ offline: true }),
        JSON.stringify({ name: 'account.updateStatus', tlName: 'TL_account_updateStatus', account: 900, field: 'request' })
    ));
    assert.strictEqual(offline.strategy, 'default');
});

test('a switch flipped in the UI takes effect without a reload', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    assert.strictEqual(hookOf(ctx, 'messages.setTyping').strategy, 'default');
    ctx.__extera.invokeSettingCallback('re_extera_ghost', 'change', JSON.stringify({ value: true }));
    assert.strictEqual(state.settings.re_extera_ghost, true);
    assert.strictEqual(hookOf(ctx, 'messages.setTyping').strategy, 'cancel');
});

test('every request the ghost covers is subscribed at load', () => {
    const state = makeHost();
    load(state, 'en-US');
    const hooks = state.calls.filter((c) => c[0] === 'addHook').map((c) => c[2]);
    for (const name of ['messages.setTyping', 'account.updateStatus', 'messages.readHistory', 'stories.readStories']) {
        assert.ok(hooks.includes(name), name + ' missing from ' + JSON.stringify(hooks));
    }
});

test('the settings screen shows no bulletin and no dead report row', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    assert.deepStrictEqual(state.bulletins, []);
    const rows = settingsOf(ctx);
    const textRows = rows.filter((r) => r.type === 'text');
    // The only tappable rows are the two the module had in its own screen: open
    // the saved history and clear it. Neither is a report about the dex.
    for (const row of textRows) {
        assert.strictEqual(row.has_click, true, row.text);
        assert.ok(['re_extera_view_deleted', 're_extera_clear_deleted'].includes(row.key), row.key);
    }
    assert.strictEqual(textRows.length, 2, JSON.stringify(textRows));
});

test('viewing the history shows both deleted and edited messages, as the module did', () => {
    const state = makeHost({
        settings: { re_extera_save_deleted_messages: true },
        store: {
            deleted_keys: [
                { peer_id: 5, id: 10, date: 100, text: 'gone', is_out: false, media_kind: 'none' },
                { peer_id: 5, id: 11, date: 200, text: '', is_out: true, media_kind: 'photo' },
            ],
            edits: [
                { peer_id: 5, id: 20, date: 300, text: 'rewritten', is_out: false, media_kind: 'none' },
            ],
        },
    });
    const ctx = load(state, 'en-US');
    const row = settingsOf(ctx).find((r) => r.key === 're_extera_view_deleted');
    ctx.__extera.invokeSettingCallback(row.key, 'click', 'null');
    assert.strictEqual(state.alerts.length, 1, JSON.stringify(state.alerts));
    const alert = state.alerts[0];
    assert.strictEqual(alert.title, 'Edited and deleted messages');
    // Newest first inside each part, both parts present, and a media-only entry
    // is marked rather than shown as an empty line.
    assert.ok(alert.message.includes('Deleted messages'), alert.message);
    assert.ok(alert.message.includes('Edited messages'), alert.message);
    assert.ok(alert.message.indexOf('#11') < alert.message.indexOf('#10'), alert.message);
    assert.ok(alert.message.includes('[photo]'), alert.message);
    assert.ok(alert.message.includes('(outgoing)'), alert.message);
    assert.ok(alert.message.includes('rewritten'), alert.message);
});

test('a deleted message survives the delete update', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    const message = {
        _: 'message',
        id: 77,
        peer_id: { _: 'peerUser', user_id: 4242 },
        from_id: { _: 'peerUser', user_id: 4242 },
        date: 1700000000,
        message: 'hello there',
        media_kind: 'none',
    };
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: message, pts: 1, pts_count: 1 }), JSON.stringify({
        name: 'updateNewMessage', tlName: 'TL_updateNewMessage', account: 900, field: 'update',
    }));
    assert.strictEqual(state.written.length, 1, 'one write');
    let store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].text, 'hello there');
    assert.strictEqual(store.deleted_keys[0].peer_id, 4242);

    // The delete carries only the id; the saved copy is what is left.
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ messages: [77] }), JSON.stringify({
        name: 'updateDeleteMessages', tlName: 'TL_updateDeleteMessages', account: 900, field: 'update',
    }));
    store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.deleted_keys[0].deleted, true);
});

test('a message the user deletes himself is kept, without any update arriving', () => {
    // The case that made "save deleted messages" look broken on iOS: deleting
    // your own message never produces `updateDeleteMessages`, and the message
    // never arrived as `updateNewMessage` either, so the plugin is told right
    // before the client removes it. The module had its own switch for this
    // ("Сохранять сообщения удаленные вручную"); `save_deleted_messages` alone
    // must not be enough.
    const state = makeHost({ settings: { re_extera_save_manually_deleted: true } });
    const ctx = load(state, 'en-US');
    const payload = JSON.stringify({
        messages: [{
            id: 91,
            peer_id: 4242,
            date: 1700000123,
            text: 'my own words',
            sender_id: 7,
            is_out: true,
            media_kind: 'none',
        }],
    });
    ctx.__extera.runHook('on_messages_will_be_deleted', payload, JSON.stringify({
        name: 'messages', account: 900, field: 'update',
    }));
    assert.strictEqual(state.written.length, 1, 'one write');
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].id, 91);
    assert.strictEqual(store.deleted_keys[0].peer_id, 4242);
    assert.strictEqual(store.deleted_keys[0].text, 'my own words');
    assert.strictEqual(store.deleted_keys[0].is_out, true);
});

test('the two deletion switches stay independent, as in the module', () => {
    // Only the remote switch is on: a message someone else deleted is kept, and
    // one the user deleted himself is not.
    const remoteOnly = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const remoteCtx = load(remoteOnly, 'en-US');
    remoteCtx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        messages: [{ id: 1, peer_id: 2, date: 3, text: 'mine', is_out: true, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.deepStrictEqual(remoteOnly.written, [], 'the own-deletion switch is off');

    const ownOnly = makeHost({ settings: { re_extera_save_manually_deleted: true } });
    const ownCtx = load(ownOnly, 'en-US');
    ownCtx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 8, peer_id: { _: 'peerUser', user_id: 3 }, message: 'theirs', date: 9 },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    assert.deepStrictEqual(ownOnly.written, [], 'the remote switch is off');
});

test('a locally deleted message is not stored twice when it also arrived as an update', () => {
    const state = makeHost({
        settings: { re_extera_save_deleted_messages: true, re_extera_save_manually_deleted: true },
    });
    const ctx = load(state, 'en-US');
    const base = { _: 'message', id: 12, peer_id: { _: 'peerUser', user_id: 5 }, date: 4, message: 'once' };
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: base }), JSON.stringify({
        name: 'updateNewMessage', account: 900, field: 'update',
    }));
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        messages: [{ id: 12, peer_id: 5, date: 4, text: 'once', sender_id: 5, is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.deleted_keys.length, 1);
});

test('nothing is stored while saving is off', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 5, peer_id: { _: 'peerChat', chat_id: 9 }, message: 'x', date: 1 },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        messages: [{ id: 6, peer_id: 9, date: 2, text: 'y', is_out: true, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.deepStrictEqual(state.written, []);
});

test('an edit replaces the saved text instead of adding a row', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    const base = { _: 'message', id: 3, peer_id: { _: 'peerUser', user_id: 1 }, date: 10 };
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: { ...base, message: 'first' } }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: { ...base, message: 'second' } }), JSON.stringify({ name: 'updateEditMessage', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.edits.length, 1);
    assert.strictEqual(store.edits[0].text, 'second');
});

test('a shadow-banned sender is hidden and everyone else is not', () => {
    const state = makeHost({
        settings: { re_extera_shadowban: true },
        store: { shadowban_users: [{ peer_id: 4242, hide_messages: true }] },
    });
    const ctx = load(state, 'en-US');
    assert.strictEqual(ctx.__extera.query('on_hide_message', JSON.stringify({ sender_id: 4242, text: 'hi' }), JSON.stringify({ account: 900 })), '{"value":true}');
    assert.strictEqual(ctx.__extera.query('on_hide_message', JSON.stringify({ sender_id: 1, text: 'hi' }), JSON.stringify({ account: 900 })), '{"value":false}');
});

test('a regex filter hides a matching message and ignores a broken one', () => {
    const state = makeHost({
        settings: { re_extera_filters_enabled: true },
        store: { regex_filters: [{ pattern: 'spam\\d+', flags: 'i' }, { pattern: '([unclosed' }] },
    });
    const ctx = load(state, 'en-US');
    assert.strictEqual(ctx.__extera.query('on_hide_message', JSON.stringify({ text: 'SPAM42 here' }), JSON.stringify({ account: 900 })), '{"value":true}');
    assert.strictEqual(ctx.__extera.query('on_hide_message', JSON.stringify({ text: 'ordinary' }), JSON.stringify({ account: 900 })), '{"value":false}');
});

test('the hiding hooks do nothing while their switches are off', () => {
    const state = makeHost({
        store: {
            shadowban_users: [{ peer_id: 77, hide_messages: true }],
            regex_filters: [{ pattern: '.*' }],
        },
    });
    const ctx = load(state, 'en-US');
    assert.strictEqual(ctx.__extera.query('on_hide_message', JSON.stringify({ sender_id: 77, text: 'x' }), JSON.stringify({ account: 900 })), '{"value":false}');
});

test('the history hooks are subscribed even when the store cannot be read', () => {
    const state = makeHost({ failStore: true });
    load(state, 'en-US');
    const hooks = state.calls.filter((c) => c[0] === 'addHook').map((c) => c[2]);
    // Channels are not a variant of the plain updates but separate constructors,
    // so a plugin that watched only the plain names never saw a channel message.
    for (const name of [
        'updateNewMessage', 'updateNewChannelMessage',
        'updateEditMessage', 'updateEditChannelMessage',
        'updateDeleteMessages', 'updateDeleteChannelMessages',
        'updateDeleteScheduledMessages',
    ]) {
        assert.ok(hooks.includes(name), name + ' missing from ' + JSON.stringify(hooks));
    }
});

test('a message in a channel is saved with its own peer id', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    // A supergroup/channel is peer namespace 2, so its peer id is channel_id + 2 * 2^32.
    const channelId = 1234;
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 55, peer_id: { _: 'peerChannel', channel_id: channelId }, date: 20, message: 'in a channel' },
        pts: 5, pts_count: 1,
    }), JSON.stringify({ name: 'updateNewChannelMessage', account: 900, field: 'update' }));
    assert.strictEqual(state.written.length, 1, 'a channel message is stored');
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].peer_id, channelId + 2 * 4294967296);
    assert.strictEqual(store.deleted_keys[0].text, 'in a channel');
});

test('a channel delete marks only the channel it named', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    const channelId = 77;
    const channelPeer = channelId + 2 * 4294967296;
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 9, peer_id: { _: 'peerChannel', channel_id: channelId }, date: 1, message: 'channel copy' },
    }), JSON.stringify({ name: 'updateNewChannelMessage', account: 900, field: 'update' }));
    // Same id in a private chat: an unrelated message that must survive.
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 9, peer_id: { _: 'peerUser', user_id: 4242 }, date: 2, message: 'private copy' },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));

    ctx.__extera.runHook('on_update_hook', JSON.stringify({ channel_id: channelId, messages: [9] }), JSON.stringify({
        name: 'updateDeleteChannelMessages', tlName: 'TL_updateDeleteChannelMessages', account: 900, field: 'update',
    }));
    const store = JSON.parse(state.written[state.written.length - 1]);
    const byPeer = {};
    for (const entry of store.deleted_keys) {
        byPeer[entry.peer_id] = entry;
    }
    assert.strictEqual(byPeer[channelPeer].deleted, true, 'the channel copy is marked');
    assert.strictEqual(byPeer[4242].deleted, undefined, 'the private copy with the same id is untouched');
});

test('a channel edit replaces the saved text', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    const channelId = 5;
    const base = { _: 'message', id: 61, peer_id: { _: 'peerChannel', channel_id: channelId }, date: 3 };
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: { ...base, message: 'before' } }), JSON.stringify({
        name: 'updateNewChannelMessage', account: 900, field: 'update',
    }));
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message: { ...base, message: 'after' } }), JSON.stringify({
        name: 'updateEditChannelMessage', account: 900, field: 'update',
    }));
    const store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.edits.length, 1);
    assert.strictEqual(store.edits[0].text, 'after');
    assert.strictEqual(store.edits[0].peer_id, channelId + 2 * 4294967296);
});

test('a scheduled delete uses the peer the update carries', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 300, peer_id: { _: 'peerUser', user_id: 8 }, date: 4, message: 'scheduled' },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        peer: { _: 'peerUser', user_id: 8 }, messages: [300],
    }), JSON.stringify({ name: 'updateDeleteScheduledMessages', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.deleted_keys[0].deleted, true);
});

test('the TL_ spelling of a channel update is understood too', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 12, peer_id: { _: 'peerChannel', channel_id: 3 }, date: 5, message: 'tl name' },
    }), JSON.stringify({ name: 'TL_updateNewChannelMessage', account: 900, field: 'update' }));
    assert.strictEqual(state.written.length, 1);
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys[0].text, 'tl name');
});

test('the local delete hook is implemented, and the host can tell', () => {
    const state = makeHost();
    const ctx = load(state, 'en-US');
    // The host asks this once per delete before describing any message.
    assert.strictEqual(ctx.__extera.hasHook('on_messages_will_be_deleted'), true);
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
    // The wording describes what the module is, not a failure: iOS has no
    // Dalvik, so this line explains why nothing is downloaded.
    assert.ok(text.includes('Dalvik module'), text);
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
    assert.deepStrictEqual(state.bulletins, [], JSON.stringify(state.bulletins));
    let answered = 'unset';
    ctx.__extera.instance.loader.fetch_version_info((info) => { answered = info; });
    assert.strictEqual(answered, null);
    const text = logText(state);
    assert.ok(text.includes('did not answer'), text);
});

test('unloading stops the loader and logs it', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    assert.ok(logText(state).includes('re:extera: plugin unloaded'));
});

test('a TL message keeps its direction and drops a null author', () => {
    // `pluginJSONValue` describes a message from the schema: the direction is
    // `out`, and an absent `from_id` arrives as `null` rather than missing. Both
    // spellings have to be handled, or an own message is stored as incoming and
    // the author becomes peer 0.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: {
            _: 'message', flags: 2, out: true, id: 400, peer_id: { _: 'peerUser', user_id: 21 },
            from_id: null, date: 6, message: 'mine',
        },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys[0].is_out, true, 'out is translated to is_out');
    assert.strictEqual(store.deleted_keys[0].peer_id, 21);
    assert.strictEqual(store.deleted_keys[0].sender_id, 0, 'no author means no sender, not peer 0');
});

test('the host can hand over a remotely deleted message it read from the database', () => {
    // The real failure on device: the delete update named only global ids, and
    // the message had never arrived as `updateNewMessage` because it came from
    // history. Nothing was stored, so nothing could be marked. The host now reads
    // the message at the moment of deletion and marks the payload `remote`.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{
            id: 830636,
            peer_id: 4242,
            date: 1700000200,
            text: 'rescued from the database',
            sender_id: 4242,
            is_out: false,
            media_kind: 'none',
        }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.strictEqual(state.written.length, 1, 'the remote switch covers it');
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].id, 830636);
    assert.strictEqual(store.deleted_keys[0].text, 'rescued from the database');
});

test('a remote delete is ignored while only the own-deletion switch is on', () => {
    // `remote` must pick the first switch, not the second: the two cover
    // different deletes and the module kept them apart.
    const state = makeHost({ settings: { re_extera_save_manually_deleted: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{ id: 5, peer_id: 6, date: 7, text: 'not kept', is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.deepStrictEqual(state.written, []);
});

test('a local delete is ignored while only the remote switch is on', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        messages: [{ id: 5, peer_id: 6, date: 7, text: 'not kept', is_out: true, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.deepStrictEqual(state.written, []);
});

test('a message first seen alive and then deleted is marked, not duplicated', () => {
    // The common order: `updateNewMessage` stores the message, then the delete
    // arrives. It must flip the existing entry rather than add a second row — and
    // a live sighting must not be able to mark anything, which is why the flag is
    // only honoured on the deletion path.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    const message = { _: 'message', id: 500, peer_id: { _: 'peerUser', user_id: 600 }, message: 'bye', date: 1700000500 };
    ctx.__extera.runHook('on_update_hook', JSON.stringify({ message }), JSON.stringify({
        name: 'updateNewMessage', account: 900, field: 'update',
    }));
    let store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.deleted_keys[0].deleted, undefined, 'alive first');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{ id: 500, peer_id: 600, date: 1700000500, text: 'bye', is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    store = JSON.parse(state.written[state.written.length - 1]);
    assert.strictEqual(store.deleted_keys.length, 1, 'one row, not two');
    assert.strictEqual(store.deleted_keys[0].deleted, true);
});

test('a message saved at the moment of deletion is already marked deleted', () => {
    // Two steps produce one fact. The delete arrives first, when the store is
    // still empty; the message itself is read from the database in the state
    // replay that follows. An entry written here must therefore be marked, or the
    // list would show it as a message that was merely seen.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{ id: 300, peer_id: 400, date: 1700000300, text: 'gone', is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].deleted, true, 'saved because it was deleted');
});

test('a message saved from an update is not marked deleted', () => {
    // The other direction: an ordinary message must not be marked, or the list
    // would call every message deleted.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 301, peer_id: { _: 'peerUser', user_id: 400 }, message: 'alive', date: 1700000301 },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    const store = JSON.parse(state.written[0]);
    assert.strictEqual(store.deleted_keys.length, 1);
    assert.strictEqual(store.deleted_keys[0].deleted, undefined);
});

// --- rows left in the chat --------------------------------------------------
//
// `on_deleted_messages` is what the host asks when it builds a chat: the saved
// copy of a message that is no longer in the database. Only entries the plugin
// itself marked `deleted` may be answered, and only for the chat it asked about,
// or a live message would be drawn twice.

function askDeleted(ctx, peerId) {
    const answer = ctx.__extera.query(
        'on_deleted_messages',
        JSON.stringify({ peer_id: peerId }),
        JSON.stringify({ account: 900, peer: peerId })
    );
    return JSON.parse(answer).value;
}

test('a deleted copy is answered for the chat it belongs to', () => {
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{ id: 700, peer_id: 800, date: 1700000700, text: 'bye', sender_id: 800, is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));

    const rows = askDeleted(ctx, 800);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].id, 700);
    assert.strictEqual(rows[0].date, 1700000700);
    assert.strictEqual(rows[0].text, 'bye');
    assert.strictEqual(rows[0].is_out, false);
    assert.strictEqual(rows[0].sender_id, 800);

    assert.deepStrictEqual(askDeleted(ctx, 801), [], 'another chat gets nothing');
});

test('a message only seen alive is not answered as a deleted row', () => {
    // `deleted_keys` doubles as the sighting log, so the filter is `deleted`.
    // Without it every message that ever passed through an update would come
    // back as a second, identical row.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 302, peer_id: { _: 'peerUser', user_id: 400 }, message: 'alive', date: 1700000302 },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));

    assert.deepStrictEqual(askDeleted(ctx, 400), []);
});

test('the deleted rows are answered only while a save switch is on', () => {
    // A saved row is the plugin's feature, so turning its switch off has to take
    // the row out of the chat too — not only stop new ones from being kept.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_messages_will_be_deleted', JSON.stringify({
        remote: true,
        messages: [{ id: 701, peer_id: 800, date: 1700000701, text: 'bye', is_out: false, media_kind: 'none' }],
    }), JSON.stringify({ name: 'messages', account: 900, field: 'update' }));
    assert.strictEqual(askDeleted(ctx, 800).length, 1);

    ctx.__extera.instance.set_setting('re_extera_save_deleted_messages', false);
    assert.deepStrictEqual(askDeleted(ctx, 800), []);

    ctx.__extera.instance.set_setting('re_extera_save_manually_deleted', true);
    assert.strictEqual(askDeleted(ctx, 800).length, 1, 'the other switch still covers the store');
});

test('an edit is not answered as a deleted row', () => {
    // An edited message is still in the chat. Its saved copy lives under
    // `edits`, and answering it here would add a row for a message the user
    // can already see.
    const state = makeHost({ settings: { re_extera_save_deleted_messages: true, re_extera_save_edits: true } });
    const ctx = load(state, 'en-US');
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 303, peer_id: { _: 'peerUser', user_id: 400 }, message: 'first', date: 1700000303 },
    }), JSON.stringify({ name: 'updateNewMessage', account: 900, field: 'update' }));
    ctx.__extera.runHook('on_update_hook', JSON.stringify({
        message: { _: 'message', id: 303, peer_id: { _: 'peerUser', user_id: 400 }, message: 'second', date: 1700000304 },
    }), JSON.stringify({ name: 'updateEditMessage', account: 900, field: 'update' }));

    assert.deepStrictEqual(askDeleted(ctx, 400), []);
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