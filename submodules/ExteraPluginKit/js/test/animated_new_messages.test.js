/*
 * Runs js/animated_new_messages.plugin through the real bootstrap against a fake
 * __host, and drives the `on_message_inserted` hook the way PluginManager does.
 *
 * The assertions are about the numbers the plugin hands the UI: style selection,
 * the speed table, intensity scaling, the outgoing mirror, comfort mode, the
 * per-chat draw, and the two switches that have to produce "no animation at all".
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'animated_new_messages.plugin'), 'utf8');

function makeHost(options) {
    options = options || {};
    const calls = [];
    const settings = Object.assign({}, options.settings || {});
    return {
        calls,
        settings,
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
            pluginDirectory: () => '/plugins/animated_new_messages',
            schedulePlugin: () => {},
        },
    };
}

function load(state) {
    const context = vm.createContext({ __host: state.host, console });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('animated_new_messages', 'Animated Messages');
    vm.runInContext(plugin, context, { filename: 'animated_new_messages.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

// Mirrors PluginManager.queryValue: the hook answers `{value: ...}`, and `null`
// there is "nothing to say".
function inserted(ctx, payload, extra) {
    const answer = JSON.parse(ctx.__extera.query(
        'on_message_inserted',
        JSON.stringify(payload),
        JSON.stringify(extra || { account: 1, isDate: false, width: 400, height: 200 })
    ));
    return answer.value === undefined ? null : answer.value;
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

const INCOMING = { id: 1, peer_id: 100, date: 1700000000, is_out: false, text: 'hi', media_kind: 'none' };
const OUTGOING = { id: 2, peer_id: 100, date: 1700000001, is_out: true, text: 'yo', media_kind: 'none' };

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const state = makeHost();
    const ctx = load(state);
    assert.strictEqual(ctx.__id__, 'animated_new_messages');
    assert.strictEqual(ctx.__name__, 'Animated Messages');
    assert.strictEqual(ctx.__version__, '2.6');
    assert.strictEqual(ctx.__author__, 'Natu');
});

test('the settings screen keeps every switch and selector of the original', () => {
    const state = makeHost();
    const ctx = load(state);
    const controls = settingsOf(ctx);
    const keys = controls.map((c) => c.key).filter(Boolean);
    // The original's twenty-one rows, minus the two dividers that are not keys.
    for (const key of [
        'enabled', 'dark_safe_mode', 'animate_when_measured', 'reduce_motion',
        'profile', 'follow_profile', 'intensity_idx',
        'anim_msgs', 'anim_style', 'anim_speed',
        'different_outgoing', 'mirror_outgoing', 'out_anim_style', 'out_anim_speed',
        'anim_dates', 'date_anim_style', 'date_pop_size', 'date_speed_idx',
        'random_per_chat', 'random_mode',
    ]) {
        assert.ok(keys.includes(key), 'missing setting ' + key);
    }
    const style = controls.find((c) => c.key === 'anim_style');
    assert.strictEqual(style.type, 'selector');
    assert.strictEqual(style.items.length, 12, 'twelve message styles');
    assert.strictEqual(controls.find((c) => c.key === 'date_anim_style').items.length, 4);
    assert.strictEqual(controls.find((c) => c.key === 'profile').items.length, 4);
    assert.strictEqual(controls.find((c) => c.key === 'intensity_idx').items.length, 4);
    assert.strictEqual(controls.find((c) => c.key === 'random_mode').items.length, 4);
});

test('turning animations off returns no animation at all', () => {
    const state = makeHost({ settings: { enabled: false } });
    const ctx = load(state);
    assert.strictEqual(inserted(ctx, INCOMING), null);
    assert.strictEqual(inserted(ctx, null, { isDate: true, width: 400, height: 40 }), null);
});

test('the balanced preset is spring rise at normal speed', () => {
    const state = makeHost({ settings: { dark_safe_mode: false } });
    const ctx = load(state);
    const animation = inserted(ctx, INCOMING);
    assert.ok(animation, 'an animation was produced');
    // Style 4 "Spring Rise": a downward offset of 32% of the row, overshooting.
    assert.strictEqual(animation.curve, 'overshoot');
    assert.ok(Math.abs(animation.translationY - 200 * 0.32) < 0.001, String(animation.translationY));
    assert.strictEqual(animation.alpha, 0.0);
    // 620ms at x1.0, shortened by intensity 1.0, then clamped.
    assert.strictEqual(animation.duration, 620);
    assert.ok(animation.overshoot > 1.8 && animation.overshoot < 2.2, String(animation.overshoot));

    // Dark safe mode is on by default and damps the overshoot, exactly as the
    // original did: either comfort mode or the safe mode pins it to 1.15.
    const safe = makeHost();
    const safeCtx = load(safe);
    assert.strictEqual(inserted(safeCtx, INCOMING).overshoot, 1.15);
    assert.strictEqual(inserted(safeCtx, INCOMING).alpha, 0.05);
});

test('each of the twelve styles reports its own motion', () => {
    // Dark safe mode collapses the spin into a plain scale, which the original
    // did too, so distinctness is checked with the effects it damps turned off.
    const state = makeHost({ settings: { follow_profile: false, dark_safe_mode: false, reduce_motion: false } });
    const ctx = load(state);

    const seen = [];
    for (let style = 0; style < 12; style += 1) {
        state.settings.anim_style = style;
        const animation = inserted(ctx, INCOMING);
        assert.ok(animation, 'style ' + style + ' produced nothing');
        seen.push(JSON.stringify(animation));
    }
    // No two styles may collapse into the same descriptor.
    assert.strictEqual(new Set(seen).size, 12, 'every style is distinct');

    state.settings.anim_style = 0;
    let soft = inserted(ctx, INCOMING);
    assert.ok(soft.scaleX < 1 && soft.scaleX >= 0.65, String(soft.scaleX));
    assert.strictEqual(soft.curve, 'decelerate');

    state.settings.anim_style = 1;
    let right = inserted(ctx, INCOMING);
    assert.ok(right.translationX > 0, 'incoming slides from the right');

    state.settings.anim_style = 8;
    let left = inserted(ctx, INCOMING);
    assert.ok(left.translationX < 0, 'style 8 slides from the left');

    state.settings.anim_style = 3;
    const flip = inserted(ctx, INCOMING);
    assert.ok(flip.rotationY > 0, 'flip turns about Y');
    assert.strictEqual(flip.curve, 'accelerateDecelerate');

    state.settings.anim_style = 5;
    const helicopter = inserted(ctx, INCOMING);
    assert.ok(helicopter.rotationZ >= 200, String(helicopter.rotationZ));
    assert.ok(Math.abs(helicopter.scaleX - 0.55) < 1e-9);

    state.settings.anim_style = 11;
    const wobble = inserted(ctx, INCOMING);
    assert.ok(Array.isArray(wobble.rotationKeyframes), 'wobble is a keyframe path');
    assert.strictEqual(wobble.rotationKeyframes.length, 4);
    assert.strictEqual(wobble.rotationKeyframes[3], 0, 'the path ends at rest');

    state.settings.anim_style = 9;
    const bounce = inserted(ctx, INCOMING);
    assert.ok(bounce.rotationX > 0, 'bounce flips about X');
});

test('speed and intensity change the duration, within the original clamps', () => {
    const state = makeHost({ settings: { follow_profile: false, anim_style: 0 } });
    const ctx = load(state);

    state.settings.anim_speed = 0;
    const slow = inserted(ctx, INCOMING).duration;
    state.settings.anim_speed = 1;
    const normal = inserted(ctx, INCOMING).duration;
    state.settings.anim_speed = 3;
    const ultra = inserted(ctx, INCOMING).duration;

    assert.ok(slow > normal, slow + ' > ' + normal);
    assert.ok(normal > ultra, normal + ' > ' + ultra);
    // x2.0 of 620 is 310; the intensity shortening applies on top.
    assert.ok(ultra >= 170, 'the fast end never goes below 170ms');

    state.settings.anim_speed = 1;
    state.settings.intensity_idx = 3;
    const insane = inserted(ctx, INCOMING).duration;
    state.settings.intensity_idx = 0;
    const low = inserted(ctx, INCOMING).duration;
    assert.ok(insane < low, 'more intensity is faster: ' + insane + ' < ' + low);
});

test('outgoing rows mirror the direction and use their own style', () => {
    const state = makeHost({ settings: { follow_profile: false, anim_style: 1, out_anim_style: 1 } });
    const ctx = load(state);

    const incoming = inserted(ctx, INCOMING);
    const outgoing = inserted(ctx, OUTGOING);
    assert.ok(incoming.translationX > 0, 'incoming from the right');
    assert.ok(outgoing.translationX < 0, 'outgoing mirrored to the left');
    assert.ok(Math.abs(outgoing.translationX) < Math.abs(incoming.translationX), 'outgoing travels 0.85 as far');

    // The separate outgoing style is used, not the incoming one.
    state.settings.out_anim_style = 2;
    assert.ok(inserted(ctx, OUTGOING).translationY > 0, 'outgoing slide-from-bottom');
    assert.strictEqual(inserted(ctx, INCOMING).translationY, undefined);

    // Turning the mirror off keeps outgoing on the same side as incoming.
    state.settings.out_anim_style = 1;
    state.settings.mirror_outgoing = false;
    assert.ok(inserted(ctx, OUTGOING).translationX > 0, 'not mirrored');

    // Turning separate-outgoing off makes outgoing use the incoming style, still
    // mirrored: style 8 slides from the left for incoming, so an outgoing row
    // mirrored by the same rule slides in from the right.
    state.settings.mirror_outgoing = true;
    state.settings.different_outgoing = false;
    state.settings.anim_style = 8;
    assert.ok(inserted(ctx, OUTGOING).translationX > 0, 'incoming style 8, mirrored for outgoing');
});

test('comfort mode removes the spinning styles', () => {
    const state = makeHost({ settings: { follow_profile: false, reduce_motion: true } });
    const ctx = load(state);

    for (const spinning of [3, 5, 9, 11]) {
        state.settings.anim_style = spinning;
        const animation = inserted(ctx, INCOMING);
        assert.strictEqual(animation.rotationY, undefined, 'style ' + spinning + ' has no Y rotation');
        assert.strictEqual(animation.rotationX, undefined, 'style ' + spinning + ' has no X rotation');
        assert.strictEqual(animation.rotationZ, undefined, 'style ' + spinning + ' has no Z rotation');
        assert.strictEqual(animation.rotationKeyframes, undefined, 'style ' + spinning + ' has no path');
        // Without a preset in charge it falls back to "Spring Rise".
        assert.ok(animation.translationY > 0, 'style ' + spinning + ' becomes spring rise');
    }

    // With a preset in charge it falls back to the preset's own style instead.
    // The "Crazy" preset is style 9 (bounce flip), so comfort mode must turn it
    // into "Soft" — a plain scale with no travel at all.
    state.settings.follow_profile = true;
    state.settings.profile = 3;
    const reduced = inserted(ctx, INCOMING);
    assert.strictEqual(reduced.translationY, undefined, 'soft has no offset');
    assert.strictEqual(reduced.rotationX, undefined);
    assert.ok(reduced.scaleX <= 0.94, 'the soft scale');

    // The same preset's date style is "Flip Tag" (2), which comfort mode
    // downgrades to "Slide + Fade".
    const date = inserted(ctx, null, { isDate: true, width: 400, height: 40 });
    assert.strictEqual(date.rotationY, undefined, 'no flip in comfort mode');
    assert.ok(date.translationY > 0, 'slide instead');
});

test('a date separator uses the date style and the date speed table', () => {
    const state = makeHost();
    const ctx = load(state);

    const pop = inserted(ctx, null, { isDate: true, width: 400, height: 40 });
    assert.ok(pop, 'a date animation');
    assert.strictEqual(pop.curve, 'overshoot');
    assert.ok(pop.scaleToX > 1.0, 'POP overshoots past its own size: ' + pop.scaleToX);
    assert.ok(pop.translationY > 0);
    // The balanced preset is date speed 1 → 600ms.
    assert.strictEqual(pop.duration, 600);

    state.settings.follow_profile = false;
    state.settings.date_speed_idx = 3;
    assert.strictEqual(inserted(ctx, null, { isDate: true, width: 400, height: 40 }).duration, 260);

    state.settings.date_anim_style = 1;
    const slide = inserted(ctx, null, { isDate: true, width: 400, height: 40 });
    assert.strictEqual(slide.rotationY, undefined);
    assert.ok(slide.translationY > 0);

    state.settings.date_anim_style = 2;
    const flip = inserted(ctx, null, { isDate: true, width: 400, height: 40 });
    assert.ok(flip.rotationY > 0);

    state.settings.date_anim_style = 3;
    const pulse = inserted(ctx, null, { isDate: true, width: 400, height: 40 });
    assert.ok(pulse.duration <= 520, 'the pulse starts with the shorter fade');

    // Dates off, messages still on.
    state.settings.anim_dates = false;
    assert.strictEqual(inserted(ctx, null, { isDate: true, width: 400, height: 40 }), null);
    assert.ok(inserted(ctx, INCOMING), 'messages are unaffected');
});

test('per-chat random is stable for a chat and differs between chats', () => {
    const state = makeHost({ settings: { follow_profile: false, random_per_chat: true, random_mode: 3 } });
    const ctx = load(state);

    const first = JSON.stringify(inserted(ctx, INCOMING));
    const again = JSON.stringify(inserted(ctx, INCOMING));
    assert.strictEqual(first, again, 'the same chat draws the same style twice');

    const other = JSON.stringify(inserted(ctx, Object.assign({}, INCOMING, { peer_id: 999 })));
    assert.notStrictEqual(first, other, 'another chat draws something else');

    // Outgoing and incoming are drawn separately, so the mirroring is not the
    // only thing that differs.
    const outgoing = JSON.stringify(inserted(ctx, OUTGOING));
    assert.notStrictEqual(first, outgoing);

    // Mode 0 randomises nothing at all: the same settings must give the same
    // answer for a different chat too.
    state.settings.random_mode = 0;
    const plainChat = JSON.stringify(inserted(ctx, Object.assign({}, INCOMING, { peer_id: 555 })));
    const knownChat = JSON.stringify(inserted(ctx, INCOMING));
    assert.strictEqual(plainChat, knownChat, 'mode 0 keeps the chosen style for every chat');
});

test('the four presets pick the styles the original lists', () => {
    // (message style, message speed, date style, date speed, date size) per
    // preset, exactly the table in the original's `profile()`.
    const table = [
        { style: 0, speed: 1, date: 1, dateSpeed: 2, dateSize: 0 },
        { style: 4, speed: 1, date: 0, dateSpeed: 1, dateSize: 1 },
        { style: 6, speed: 2, date: 0, dateSpeed: 1, dateSize: 2 },
        { style: 9, speed: 3, date: 2, dateSpeed: 3, dateSize: 3 },
    ];

    for (let profile = 0; profile < 4; profile += 1) {
        const preset = makeHost({ settings: { profile: profile, dark_safe_mode: false } });
        const presetCtx = load(preset);

        // The same preset's values, entered by hand with the preset switch off.
        const manual = makeHost({
            settings: {
                profile: profile,
                follow_profile: false,
                dark_safe_mode: false,
                anim_style: table[profile].style,
                anim_speed: table[profile].speed,
                date_anim_style: table[profile].date,
                date_speed_idx: table[profile].dateSpeed,
                date_pop_size: table[profile].dateSize,
            },
        });
        const manualCtx = load(manual);

        assert.strictEqual(
            JSON.stringify(inserted(presetCtx, INCOMING)),
            JSON.stringify(inserted(manualCtx, INCOMING)),
            'preset ' + profile + ' message'
        );
        const dateOptions = { isDate: true, width: 400, height: 40 };
        assert.strictEqual(
            JSON.stringify(inserted(presetCtx, null, dateOptions)),
            JSON.stringify(inserted(manualCtx, null, dateOptions)),
            'preset ' + profile + ' date'
        );
    }
});

test('dark safe mode starts from a visible alpha instead of zero', () => {
    const state = makeHost({ settings: { dark_safe_mode: true } });
    const ctx = load(state);
    assert.strictEqual(inserted(ctx, INCOMING).alpha, 0.05);

    state.settings.dark_safe_mode = false;
    assert.strictEqual(inserted(ctx, INCOMING).alpha, 0.0);
});

test('a row with no size still animates against a fallback size', () => {
    const state = makeHost({ settings: { follow_profile: false, anim_style: 1 } });
    const ctx = load(state);
    const animation = inserted(ctx, INCOMING, { isDate: false, width: 0, height: 0 });
    // 540 is the fallback width, so a slide is 0.55 of it.
    assert.ok(Math.abs(animation.translationX - 540 * 0.55) < 0.001, String(animation.translationX));
});

let failures = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failures += 1;
        console.log('FAIL ' + name);
        console.log('     ' + (error && error.message ? error.message : error));
    }
}
console.log('');
console.log((tests.length - failures) + '/' + tests.length + ' passed');
process.exit(failures === 0 ? 0 : 1);