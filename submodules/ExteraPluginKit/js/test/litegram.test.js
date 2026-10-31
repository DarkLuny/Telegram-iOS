/*
 * Runs js/litegram.plugin through the real bootstrap against a fake __host, and
 * drives the settings hook the way PluginManager does.
 *
 * What matters here: the original's 58 keys survive with the same spellings, the
 * four sections keep their rows and order, `switch_all` flips a whole group the
 * way the Python did, and the one hook that has a real iOS surface
 * (`on_settings_rows_hook`) hides exactly the rows the switches name - including
 * the Help section, which is three rows behind one switch.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'litegram.plugin'), 'utf8');

// The plugin reads the device language, which `LocaleController` answered on
// Android. Pinning it keeps a test from depending on the machine it runs on.
function makeIntl(locale) {
    // Called without `new` by the plugin, so the fake has to work both ways.
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
    return {
        calls,
        settings,
        host: {
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
            showBulletin: (id, kind, json) => calls.push(['bulletin', kind, json]),
            showAlert: () => {},
            dismissAlert: () => {},
            fileOp: () => 'null',
            selectedAccount: () => 0,
            pluginDirectory: () => '/plugins/litegram',
            schedulePlugin: () => {},
            openUrl: (id, url) => { calls.push(['openUrl', url]); return true; },
            themeColors: () => '{}',
        },
    };
}

function load(state, locale) {
    const context = vm.createContext({ __host: state.host, console, Intl: makeIntl(locale) });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('litegram', 'LiteGram');
    vm.runInContext(plugin, context, { filename: 'litegram.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

function controlOf(ctx, key) {
    return settingsOf(ctx).find((control) => control.key === key);
}

// Mirrors PluginManager.dispatchSettingsRowExclusions: the plugin is asked with
// the offered keys and answers with the subset to keep.
function askRows(ctx, offered) {
    const answer = JSON.parse(ctx.__extera.query(
        'on_settings_rows_hook',
        JSON.stringify({ keys: offered }),
        JSON.stringify({ account: 1 })
    ));
    if (answer.value === null || answer.value === undefined) {
        return offered;
    }
    const kept = new Set(answer.value);
    return offered.filter((key) => kept.has(key));
}

const ALL_ROWS = ['premium', 'stars', 'ton', 'wallet', 'business', 'sendGift', 'support', 'faq', 'tips'];

// Turns the nested settings pages into a flat list of every control.
function allControls(ctx) {
    const result = [];
    for (const parent of settingsOf(ctx)) {
        result.push(parent);
        if (parent.has_sub_fragment) {
            for (const child of JSON.parse(ctx.__extera.collectSubSettings(parent.key))) {
                result.push(child);
            }
        }
    }
    return result;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.__id__, 'litegram');
    assert.strictEqual(ctx.__name__, 'LiteGram');
    assert.strictEqual(ctx.__version__, '1.6.2');
    assert.strictEqual(ctx.__min_version__, '12.1.1');
    assert.deepStrictEqual(Array.from(ctx.__category__), ['appearance']);
    assert.strictEqual(ctx.GITHUB_URL, 'https://github.com/nonFeature/LiteGram');
});

test('the four top-level sections are the original four, in order', () => {
    const ctx = load(makeHost());
    const top = settingsOf(ctx);
    assert.strictEqual(top.length, 4);
    const texts = top.map((row) => row.text);
    assert.deepStrictEqual(texts, ['Chat', 'Profile', 'Interface', 'About']);
    for (const row of top) {
        assert.strictEqual(row.type, 'text');
        assert.ok(row.has_sub_fragment, row.text + ' should open a page');
    }
    assert.deepStrictEqual(
        top.map((row) => row.link_alias),
        ['chatSettings', 'profileSettings', 'interfaceSettings', 'aboutSettings']
    );
});

test('every one of the original 58 keys appears in the settings tree', () => {
    const ctx = load(makeHost());
    const expected = [
        'switchAll', 'hidePremiumRow', 'hideStarsRow', 'hideTonRow', 'hideWalletRow',
        'hideBusinessRow', 'hideSendAGiftRow', 'hideHelpSection', 'chatSettings',
        'profileSettings', 'interfaceSettings', 'aboutSettings', 'drawerSettings',
        'hideProfileActionsStreamButton', 'hideStories', 'hideActionBarStatus',
        'hideGreetingButton', 'hideGroupStickers', 'hideProfileActionsStoriesButton',
        'hideProfileActionsGiftButton', 'hideStoriesTab', 'hideGiftsTab',
        'replyElements', 'hideProfileBackgroundEmoji', 'hideProfilePinnedGifts',
        'hideProfileColorfulBackground', 'hideBoostBadge', 'hideProfileMusic',
        'hideProfileBusiness', 'hidePremiumEmojiKeyboard', 'hidePremiumEmojiReactions',
        'hidePremiumSearch', 'hidePremiumSuggestions', 'switchAllPremiumEmoji',
        'hidePremiumStickersRecent', 'hidePremiumStickersSearch',
        'hidePremiumStickersGrid', 'switchAllPremiumStickers', 'hidePremiumBadge',
        'hideBotVerification', 'hidePremiumFeatures', 'hideArticlesEditor',
        'hideAiButton', 'hideAiSummarize', 'hideActionBarLiveStream',
        'hideActionBarArchivedStories', 'hideActionBarSendGift',
        'hideActionBarBoostGroup', 'hideActionBarAddShortcut', 'hideActionBarReport',
        'hideActionBarClearHistory', 'hideBottomGiftButton', 'hideGiftCards',
        'hideGiveawayCards', 'hideCollectibleStatus', 'hideStarsRating',
        'hideStarReaction', 'hideEmojiSearch'
    ];
    assert.strictEqual(expected.length, 58);
    const present = new Set(allControls(ctx).map((control) => control.link_alias || control.key));
    for (const key of expected) {
        assert.ok(present.has(key), 'missing key ' + key);
    }
});

test('a settings export keys on the original spellings, not row positions', () => {
    const ctx = load(makeHost());
    // The Python plugin stored settings under `Keys.*`, so an export must carry
    // camelCase names. A control without a key would be stored positionally and
    // would break the round-trip.
    const switches = allControls(ctx).filter((control) => control.type === 'switch');
    assert.ok(switches.length >= 40, 'expected many switches, got ' + switches.length);
    for (const control of switches) {
        assert.ok(/^[a-zA-Z]+$/.test(control.key), 'unexpected key ' + control.key);
    }
});

test('Interface holds the seven settings rows and lists them in the original order', () => {
    const ctx = load(makeHost());
    const rows = JSON.parse(ctx.__extera.collectSubSettings('interfaceSettings'));
    const keys = rows.filter((row) => row.type === 'switch').map((row) => row.key);
    assert.deepStrictEqual(keys, [
        'hidePremiumRow', 'hideStarsRow', 'hideTonRow', 'hideWalletRow',
        'hideBusinessRow', 'hideSendAGiftRow', 'hideHelpSection',
        'hidePremiumFeatures', 'hideArticlesEditor', 'hideAiButton', 'hideAiSummarize'
    ]);
});

test('the premium emoji and sticker groups default to on, as the original did', () => {
    const ctx = load(makeHost());
    const rows = JSON.parse(ctx.__extera.collectSubSettings('chatSettings'));
    const byKey = {};
    for (const row of rows) {
        if (row.key) {
            byKey[row.key] = row.value;
        }
    }
    for (const key of ['hidePremiumEmojiKeyboard', 'hidePremiumEmojiReactions',
        'hidePremiumSearch', 'hidePremiumSuggestions', 'hidePremiumStickersRecent',
        'hidePremiumStickersSearch', 'hidePremiumStickersGrid']) {
        assert.strictEqual(byKey[key], true, key + ' should default to on');
    }
    // Everything that is not in a "hide premium" group starts off.
    assert.strictEqual(byKey.hidePremiumRow, undefined);
    assert.strictEqual(byKey.hideGiftCards, false);

    const interfaceRows = JSON.parse(ctx.__extera.collectSubSettings('interfaceSettings'));
    const premiumRow = interfaceRows.find((row) => row.key === 'hidePremiumRow');
    assert.strictEqual(premiumRow.value, false);
});

test('the collectible status switch disappears once the premium badge is hidden', () => {
    const shown = load(makeHost({ settings: { hidePremiumBadge: false } }));
    const withRow = JSON.parse(shown.__extera.collectSubSettings('profileSettings'));
    assert.ok(withRow.some((row) => row.key === 'hideCollectibleStatus'));

    const hidden = load(makeHost({ settings: { hidePremiumBadge: true } }));
    const withoutRow = JSON.parse(hidden.__extera.collectSubSettings('profileSettings'));
    assert.ok(!withoutRow.some((row) => row.key === 'hideCollectibleStatus'));
});

test('nothing is hidden while every settings-row switch is off', () => {
    const ctx = load(makeHost());
    assert.deepStrictEqual(askRows(ctx, ALL_ROWS), ALL_ROWS);
});

test('each settings-row switch hides its own row and only its own', () => {
    const cases = [
        ['hidePremiumRow', 'premium'],
        ['hideStarsRow', 'stars'],
        ['hideTonRow', 'ton'],
        ['hideWalletRow', 'wallet'],
        ['hideBusinessRow', 'business'],
        ['hideSendAGiftRow', 'sendGift']
    ];
    for (const [setting, row] of cases) {
        const ctx = load(makeHost({ settings: { [setting]: true } }));
        const kept = askRows(ctx, ALL_ROWS);
        assert.deepStrictEqual(kept, ALL_ROWS.filter((key) => key !== row), setting);
    }
});

test('the Help switch removes all three rows of the section at once', () => {
    const ctx = load(makeHost({ settings: { hideHelpSection: true } }));
    assert.deepStrictEqual(askRows(ctx, ALL_ROWS), ['premium', 'stars', 'ton', 'wallet', 'business', 'sendGift']);
});

test('several switches combine, and an unknown key is never removed', () => {
    const ctx = load(makeHost({ settings: { hidePremiumRow: true, hideWalletRow: true } }));
    assert.deepStrictEqual(askRows(ctx, ALL_ROWS), ['stars', 'ton', 'business', 'sendGift', 'support', 'faq', 'tips']);
    // The host only asks about rows it is about to build; an answer that named
    // something else must not be able to hide it.
    assert.deepStrictEqual(askRows(ctx, ['premium', 'stars']), ['stars']);
    assert.deepStrictEqual(askRows(ctx, ['somethingElse']), ['somethingElse']);
});

test('the hook keeps the offered order rather than inventing one', () => {
    const ctx = load(makeHost({ settings: { hideStarsRow: true } }));
    const reordered = ['tips', 'stars', 'premium', 'faq'];
    assert.deepStrictEqual(askRows(ctx, reordered), ['tips', 'premium', 'faq']);
});

test('a hook that fires before on_plugin_load still answers from the store', () => {
    const state = makeHost({ settings: { hideTonRow: true } });
    const context = vm.createContext({ __host: state.host, console, Intl: makeIntl('en-US') });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('litegram', 'LiteGram');
    vm.runInContext(plugin, context, { filename: 'litegram.plugin' });
    vm.runInContext('__extera.finalize()', context);
    const answer = JSON.parse(context.__extera.query(
        'on_settings_rows_hook',
        JSON.stringify({ keys: ALL_ROWS }),
        JSON.stringify({ account: 1 })
    ));
    assert.ok(Array.isArray(answer.value));
    assert.ok(answer.value.indexOf('ton') === -1);
});

test('an unloaded plugin answers nothing, so no row is hidden by a dead plugin', () => {
    const state = makeHost({ settings: { hidePremiumRow: true } });
    const context = vm.createContext({ __host: state.host, console, Intl: makeIntl('en-US') });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext(plugin, context, { filename: 'litegram.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    const answer = JSON.parse(context.__extera.query(
        'on_settings_rows_hook',
        JSON.stringify({ keys: ALL_ROWS }),
        JSON.stringify({ account: 1 })
    ));
    assert.strictEqual(answer.value, null);
});

test('Switch All turns the whole group on, then off again', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.invokeSettingCallback('switchAll', 'click', 'null');
    for (const key of ['hidePremiumRow', 'hideStarsRow', 'hideTonRow', 'hideWalletRow',
        'hideBusinessRow', 'hideSendAGiftRow', 'hideHelpSection']) {
        assert.strictEqual(state.settings[key], true, key + ' should be on');
    }
    ctx.__extera.invokeSettingCallback('switchAll', 'click', 'null');
    for (const key of ['hidePremiumRow', 'hideStarsRow', 'hideTonRow', 'hideWalletRow',
        'hideBusinessRow', 'hideSendAGiftRow', 'hideHelpSection']) {
        assert.strictEqual(state.settings[key], false, key + ' should be off');
    }
});

test('Switch All leaves a half-on group on, matching the original logic', () => {
    const state = makeHost({ settings: { hideStarsRow: true } });
    const ctx = load(state);
    // One row is already on, so the group is not fully on and the link turns
    // everything on rather than off.
    ctx.__extera.invokeSettingCallback('switchAll', 'click', 'null');
    assert.strictEqual(state.settings.hidePremiumRow, true);
    assert.strictEqual(state.settings.hideStarsRow, true);
});

test('the premium group links switch their own rows only', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.invokeSettingCallback('switchAllPremiumEmoji', 'click', 'null');
    for (const key of ['hidePremiumEmojiKeyboard', 'hidePremiumEmojiReactions',
        'hidePremiumSearch', 'hidePremiumSuggestions']) {
        assert.strictEqual(state.settings[key], false, key + ' should have been turned off');
    }
    assert.strictEqual(state.settings.hidePremiumStickersRecent, undefined);

    ctx.__extera.invokeSettingCallback('switchAllPremiumStickers', 'click', 'null');
    for (const key of ['hidePremiumStickersRecent', 'hidePremiumStickersSearch',
        'hidePremiumStickersGrid']) {
        assert.strictEqual(state.settings[key], false, key + ' should have been turned off');
    }
});

test('the premium badge switch also drives the collectible status', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.invokeSettingCallback('hidePremiumBadge', 'change', 'true');
    assert.strictEqual(state.settings.hidePremiumBadge, true);
    assert.strictEqual(state.settings.hideCollectibleStatus, true);
});

test('turning the premium badge on offers a restart, turning it off does not', () => {
    const state = makeHost();
    const ctx = load(state);
    state.calls.length = 0;
    ctx.__extera.invokeSettingCallback('hidePremiumBadge', 'change', 'false');
    const bulletins = state.calls.filter((call) => call[0] === 'bulletin');
    assert.strictEqual(bulletins.length, 1);
    const payload = JSON.parse(bulletins[0][2]);
    assert.strictEqual(payload.kind, 'button');
    assert.strictEqual(payload.button, 'RESTART');

    state.calls.length = 0;
    ctx.__extera.invokeSettingCallback('hidePremiumBadge', 'change', 'true');
    assert.strictEqual(state.calls.filter((call) => call[0] === 'bulletin').length, 0);
});

test('the restart button accepts the tap instead of killing the process', () => {
    const state = makeHost();
    const ctx = load(state);
    ctx.__extera.invokeSettingCallback('hidePremiumBadge', 'change', 'false');
    const payload = JSON.parse(state.calls.filter((call) => call[0] === 'bulletin')[0][2]);
    state.calls.length = 0;
    ctx.__extera.runCallback(payload.token);
    const again = state.calls.filter((call) => call[0] === 'bulletin');
    assert.strictEqual(again.length, 1);
    assert.strictEqual(JSON.parse(again[0][2]).kind, 'info');
});

test('the About page opens the repository through the host', () => {
    const state = makeHost();
    const ctx = load(state);
    const rows = JSON.parse(ctx.__extera.collectSubSettings('aboutSettings'));
    const link = rows.find((row) => row.has_click);
    assert.ok(link, 'the repository row should be tappable');
    state.calls.length = 0;
    ctx.__extera.invokeSettingCallback(link.key, 'click', 'null');
    const opened = state.calls.filter((call) => call[0] === 'openUrl');
    assert.strictEqual(opened.length, 1);
    assert.strictEqual(opened[0][1], 'https://github.com/nonFeature/LiteGram');
});

test('the English and Russian tables carry the same 81 keys', () => {
    const ctx = load(makeHost());
    const english = Object.keys(ctx.STRINGS.en).sort();
    const russian = Object.keys(ctx.STRINGS.ru).sort();
    assert.strictEqual(english.length, 81);
    assert.deepStrictEqual(english, russian);
});

test('a missing key is visible rather than blank', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.t('no_such_key'), 'MISSING: no_such_key');
});

test('rows carry the translated labels, not the key names', () => {
    const ctx = load(makeHost());
    const rows = JSON.parse(ctx.__extera.collectSubSettings('interfaceSettings'));
    const premium = rows.find((row) => row.key === 'hidePremiumRow');
    assert.strictEqual(premium.text, 'Hide «Telegram Premium»');
    const help = rows.find((row) => row.key === 'hideHelpSection');
    assert.strictEqual(help.text, 'Hide «Help» Section');
});

test('switches that only exist on Android are reported once at load, not silently', () => {
    const state = makeHost({ settings: { hideGiftCards: true, hideStarReaction: true } });
    load(state);
    const logs = state.calls.filter((call) => call[0] === 'log');
    assert.strictEqual(logs.length, 1);
    assert.ok(logs[0][2].indexOf('hideGiftCards') > 0, logs[0][2]);
    assert.ok(logs[0][2].indexOf('hideStarReaction') > 0, logs[0][2]);

    const quiet = makeHost();
    load(quiet);
    assert.strictEqual(quiet.calls.filter((call) => call[0] === 'log').length, 0);
});

let failed = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed += 1;
        console.log('FAIL ' + name);
        console.log('     ' + (error && error.message ? error.message : error));
    }
}
console.log('');
console.log((tests.length - failed) + '/' + tests.length + ' passed');
if (failed > 0) {
    process.exit(1);
}