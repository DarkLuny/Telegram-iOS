/*
 * Runs js/monocolorui.plugin through the real bootstrap against a fake __host,
 * and drives the two appearance hooks the way PluginManager does.
 *
 * What matters here is the colour that reaches the interface: which source is
 * used, how `#RRGGBB` is parsed, what the gradient partner is, which switches
 * gate the two hooks, and that a plugin with every switch off says nothing at
 * all instead of painting the app in the default colour.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'monocolorui.plugin'), 'utf8');

const THEME = {
    button: 0x3390ec,
    accent: 0x007aff,
    header: 0x8e8e93,
    link: 0x1b7fdb,
    floatingButton: 0xd14d4d,
    outgoing: 0xeeffde
};

function makeHost(options) {
    options = options || {};
    const calls = [];
    const settings = Object.assign({}, options.settings || {});
    const theme = Object.assign({}, THEME, options.theme || {});
    return {
        calls,
        settings,
        theme,
        host: {
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
            showBulletin: () => {},
            showAlert: () => {},
            dismissAlert: () => {},
            fileOp: () => 'null',
            selectedAccount: () => 0,
            pluginDirectory: () => '/plugins/monocolorui',
            schedulePlugin: () => {},
            // The bridge the plugin reads "take the colour from the theme" with.
            // Answers only the names it was asked for, like the real host.
            themeColors: (id, namesJSON) => {
                const names = JSON.parse(namesJSON || '[]');
                const answer = {};
                for (const name of names) {
                    if (name in theme) {
                        answer[name] = theme[name];
                    }
                }
                return JSON.stringify(answer);
            },
        },
    };
}

function load(state) {
    const context = vm.createContext({ __host: state.host, console });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('monocolorui', 'MonoColor UI');
    vm.runInContext(plugin, context, { filename: 'monocolorui.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

// Mirrors PluginManager.queryValue: `{value: ...}`, and `null` is "nothing to
// say". `undefined` from the plugin arrives as `null` too, which is the point.
function ask(ctx, event) {
    const answer = JSON.parse(ctx.__extera.query(
        event,
        'null',
        JSON.stringify({ account: 1 })
    ));
    return answer.value === undefined ? null : answer.value;
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

function controlOf(ctx, key) {
    return settingsOf(ctx).find((control) => control.key === key);
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.__id__, 'monocolorui');
    assert.strictEqual(ctx.__name__, 'MonoColor UI');
    assert.strictEqual(ctx.__version__, '1.7');
    assert.strictEqual(ctx.__author__, '@limeplug');
});

test('the settings screen keeps every key and default of the original', () => {
    const ctx = load(makeHost());
    const controls = settingsOf(ctx);
    assert.strictEqual(controlOf(ctx, 'color_source').type, 'selector');
    for (const key of ['gradient', 'avatars', 'stories', 'names', 'dialogs', 'profiles']) {
        const control = controlOf(ctx, key);
        assert.ok(control, 'missing switch ' + key);
        assert.strictEqual(control.type, 'switch');
    }
    const values = {};
    for (const control of controls) {
        if (control.key) {
            values[control.key] = control.value;
        }
    }
    assert.strictEqual(values.color_source, 0);
    assert.strictEqual(values.gradient, false);
    for (const key of ['avatars', 'stories', 'names', 'dialogs', 'profiles']) {
        assert.strictEqual(values[key], true, key + ' should default to on');
    }
});

test('the source selector lists all seven sources with their current colour', () => {
    const ctx = load(makeHost());
    const items = controlOf(ctx, 'color_source').items;
    assert.strictEqual(items.length, 7);
    assert.ok(items[0].indexOf('Кнопка') === 0, items[0]);
    assert.ok(items[1].indexOf('Акцент') === 0, items[1]);
    assert.ok(items[2].indexOf('Шапка') === 0, items[2]);
    assert.ok(items[3].indexOf('Ссылки') === 0, items[3]);
    assert.ok(items[4].indexOf('Плавающая кнопка') === 0, items[4]);
    assert.ok(items[5].indexOf('Исходящие') === 0, items[5]);
    assert.ok(items[6].indexOf('Свой') === 0, items[6]);
    // The colour each source currently resolves to comes from the live theme.
    assert.ok(items[0].indexOf('#3390EC') > 0, items[0]);
    assert.ok(items[5].indexOf('#EEFFDE') > 0, items[5]);
    // The selected one is marked, and by default that is the first.
    assert.ok(items[0].indexOf('✓') > 0, items[0]);
    assert.strictEqual(items[1].indexOf('✓'), -1);
});

test('source 0 paints the interface with the add-button colour', () => {
    const ctx = load(makeHost());
    const theme = ask(ctx, 'on_theme_colors');
    assert.strictEqual(theme.main, THEME.button);
    assert.strictEqual(theme.outgoing, THEME.button);
    assert.strictEqual(theme.names, true);
    assert.strictEqual(theme.avatars, true);
    assert.strictEqual(theme.dialogs, true);
    assert.strictEqual(theme.profiles, true);
    assert.strictEqual(theme.secondary, undefined);
});

test('every source index reads its own theme slot', () => {
    const slots = ['button', 'accent', 'header', 'link', 'floatingButton', 'outgoing'];
    for (let index = 0; index < slots.length; index += 1) {
        const ctx = load(makeHost({ settings: { color_source: index } }));
        const theme = ask(ctx, 'on_theme_colors');
        assert.strictEqual(theme.main, THEME[slots[index]], 'source ' + index);
        const names = ask(ctx, 'on_name_colors');
        assert.strictEqual(names.main, THEME[slots[index]], 'source ' + index);
    }
});

test('a source missing from the theme falls back to the plugin default', () => {
    const ctx = load(makeHost({ theme: { button: undefined }, settings: { color_source: 0 } }));
    // `undefined` deletes the slot when spread, so the host answers nothing for
    // it; the plugin has to use its own default rather than throw.
    const theme = ask(ctx, 'on_theme_colors');
    assert.strictEqual(theme.main, 0x4faede);
});

test('the custom source uses custom_color and falls back on junk', () => {
    const cases = [
        ['#4FAEDE', 0x4faede],
        ['4FAEDE', 0x4faede],
        ['#4fa', 0x44ffaa],
        ['#FF4FAEDE', 0x4faede],
        ['#GGGGGG', 0x4faede],
        ['', 0x4faede],
        ['#12345', 0x4faede]
    ];
    for (const [text, expected] of cases) {
        const ctx = load(makeHost({ settings: { color_source: 6, custom_color: text } }));
        const theme = ask(ctx, 'on_theme_colors');
        assert.strictEqual(theme.main, expected, 'parsing ' + JSON.stringify(text));
    }
});

test('an out-of-range color_source is clamped to the first source', () => {
    for (const value of [-1, 7, 99, 'nonsense']) {
        const ctx = load(makeHost({ settings: { color_source: value } }));
        const theme = ask(ctx, 'on_theme_colors');
        assert.strictEqual(theme.main, THEME.button, 'value ' + value);
    }
});

test('the custom colour field only appears for the custom source', () => {
    const plain = load(makeHost({ settings: { color_source: 1 } }));
    assert.strictEqual(controlOf(plain, 'custom_color'), undefined);

    const custom = load(makeHost({ settings: { color_source: 6 } }));
    const field = controlOf(custom, 'custom_color');
    assert.ok(field, 'custom colour field should appear');
    assert.strictEqual(field.type, 'input');
});

test('the gradient switch adds a second, visibly different stop', () => {
    const ctx = load(makeHost({ settings: { gradient: true } }));
    const theme = ask(ctx, 'on_theme_colors');
    assert.ok(typeof theme.secondary === 'number', 'secondary should be set');
    assert.notStrictEqual(theme.secondary, theme.main);
    const names = ask(ctx, 'on_name_colors');
    assert.strictEqual(names.secondary, theme.secondary);
});

test('the gradient partner lightens dark tones and darkens light ones', () => {
    const dark = load(makeHost({ settings: { gradient: true, color_source: 0 } }));
    const darkValue = ask(dark, 'on_theme_colors');
    // 0x3390ec is a mid-blue; its partner has to move away from it.
    assert.notStrictEqual(darkValue.secondary, darkValue.main);
    const darkChannel = (darkValue.secondary >> 16) & 0xff;
    assert.ok(darkChannel < ((darkValue.main >> 16) & 0xff), 'a dark tone should lighten');

    const light = load(makeHost({
        settings: { gradient: true, color_source: 1 },
        theme: { accent: 0xf5f5f5 }
    }));
    const lightValue = ask(light, 'on_theme_colors');
    assert.ok(lightValue.secondary < 0xf5f5f5, 'a near-white tone should darken');
});

test('the repaint switches reach both hooks', () => {
    const ctx = load(makeHost({ settings: { names: false, avatars: false, stories: false } }));
    const theme = ask(ctx, 'on_theme_colors');
    assert.strictEqual(theme.names, false);
    assert.strictEqual(theme.avatars, false);
    assert.strictEqual(theme.stories, false);
    assert.strictEqual(theme.dialogs, true);
    assert.strictEqual(theme.profiles, true);
});

test('names, avatars and stories off means the palette is left alone', () => {
    const ctx = load(makeHost({
        settings: { names: false, avatars: false, stories: false }
    }));
    assert.strictEqual(ask(ctx, 'on_name_colors'), null);
    // The interface itself is still recoloured, because dialogs and profiles
    // are separate switches.
    assert.ok(ask(ctx, 'on_theme_colors') !== null);
});

test('every switch off means no answer at all', () => {
    const ctx = load(makeHost({
        settings: {
            names: false, avatars: false, stories: false,
            dialogs: false, profiles: false
        }
    }));
    assert.strictEqual(ask(ctx, 'on_theme_colors'), null);
    assert.strictEqual(ask(ctx, 'on_name_colors'), null);
});

test('a hook that fires before on_plugin_load still answers from the store', () => {
    // A real load always calls `on_plugin_load` before any hook, but the
    // settings are already in the store at construction time, so answering
    // early is both safe and better than blocking the theme on a lifecycle
    // call that may be late. What must not happen is a throw.
    const state = makeHost({ settings: { color_source: 1 } });
    const context = vm.createContext({ __host: state.host, console });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('monocolorui', 'MonoColor UI');
    vm.runInContext(plugin, context, { filename: 'monocolorui.plugin' });
    vm.runInContext('__extera.finalize()', context);
    const answer = JSON.parse(context.__extera.query('on_theme_colors', 'null', '{"account":1}'));
    assert.ok(answer.value, 'should answer, not throw');
    assert.strictEqual(answer.value.main, THEME.accent);
});

test('an unloaded plugin answers nothing', () => {
    const state = makeHost();
    const context = vm.createContext({ __host: state.host, console });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext(plugin, context, { filename: 'monocolorui.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_unload', '{}');
    const theme = JSON.parse(context.__extera.query('on_theme_colors', 'null', '{"account":1}'));
    assert.strictEqual(theme.value, null);
    const names = JSON.parse(context.__extera.query('on_name_colors', 'null', '{"account":1}'));
    assert.strictEqual(names.value, null);
});

test('the source row label always carries the resolved colour', () => {
    const ctx = load(makeHost({ settings: { color_source: 6, custom_color: '#123456' } }));
    const items = controlOf(ctx, 'color_source').items;
    assert.ok(items[6].indexOf('#123456') > 0, items[6]);
    assert.ok(items[6].indexOf('✓') > 0, items[6]);
    const note = settingsOf(ctx).find((control) => control.type === 'text');
    assert.ok(note, 'a summary row should be present');
    assert.ok(note.text.indexOf('#123456') > 0, note.text);
});

test('every section header carries its text, not an empty label', () => {
    // `Header(...)` takes an options object; a bare string leaves `text` empty
    // and the screen shows a blank separator instead of the section title.
    const ctx = load(makeHost());
    const headers = settingsOf(ctx).filter((control) => control.type === 'header');
    assert.ok(headers.length > 0, 'the screen has section headers');
    for (const header of headers) {
        assert.ok(header.text, 'a header with no text');
    }
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