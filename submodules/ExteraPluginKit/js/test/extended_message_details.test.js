/*
 * Runs js/extended_message_details.plugin through the real bootstrap against a
 * fake __host, and drives `on_message_details` the way PluginManager does.
 *
 * The assertions are about the rows that reach the screen: their order, which
 * ones are omitted rather than shown empty, the number formatting, and that a
 * malformed message yields what was built before the failure instead of an
 * exception.
 *
 * Nothing here depends on the machine's timezone or language: the expected
 * timestamps are produced with the same `Date` the plugin uses, and the language
 * is injected.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const dir = path.join(__dirname, '..', '..');
const bootstrap = fs.readFileSync(path.join(dir, 'js', 'bootstrap.js'), 'utf8');
const plugin = fs.readFileSync(path.join(dir, 'js', 'extended_message_details.plugin'), 'utf8');

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
            pluginDirectory: () => '/plugins/extended_message_details',
            schedulePlugin: () => {},
            themeColors: () => '{}',
        },
    };
}

function load(state, locale) {
    const context = vm.createContext({
        __host: state.host,
        console,
        // The plugin asks the engine for the device language, which is what
        // `LocaleController` answered on Android. Pinning it keeps a test from
        // depending on the machine it runs on.
        Intl: {
            DateTimeFormat: function DateTimeFormat() {
                this.resolvedOptions = () => ({ locale: locale || 'en-US' });
            }
        }
    });
    state.context = context;
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    context.__extera.setIdentity('extended_message_details', 'Extended Message Details');
    vm.runInContext(plugin, context, { filename: 'extended_message_details.plugin' });
    vm.runInContext('__extera.finalize()', context);
    context.__extera.callLifecycleJSON('on_plugin_load', '{}');
    return context;
}

function details(ctx, message) {
    const answer = JSON.parse(ctx.__extera.query(
        'on_message_details',
        JSON.stringify(message),
        JSON.stringify({ account: 1 })
    ));
    return answer.value === undefined ? null : answer.value;
}

function titleValuePairs(rows) {
    return rows.map((row) => [row.title, row.value]);
}

function find(rows, title) {
    return rows.find((row) => row.title === title);
}

function settingsOf(ctx) {
    return JSON.parse(ctx.__extera.collectSettings());
}

// `dd.mm.yyyy hh:mm:ss` in the process timezone, which is what the plugin
// produces and what the original's fallback produced. Written out here rather
// than hard-coded so the test passes in any timezone.
function pad2(value) {
    return String(value).padStart(2, '0');
}

function stamp(ts) {
    const date = new Date(ts * 1000);
    return pad2(date.getDate()) + '.' + pad2(date.getMonth() + 1) + '.' +
        date.getFullYear() + ' ' + pad2(date.getHours()) + ':' +
        pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

const DATE = 1700000000;

const BASE = {
    id: 4242,
    peer_id: 100,
    date: DATE,
    is_out: false,
    text: 'hello',
    media_kind: 'none'
};

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('metadata matches the original plugin', () => {
    const ctx = load(makeHost());
    assert.strictEqual(ctx.__id__, 'extended_message_details');
    assert.strictEqual(ctx.__name__, 'Extended Message Details');
    assert.strictEqual(ctx.__version__, '1.0.1');
    assert.strictEqual(ctx.__author__, '@thrzxd • @kotilnya');
});

test('a plain text message gives just its id and date', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, BASE);
    assert.deepStrictEqual(titleValuePairs(rows), [
        ['ID', '4242'],
        ['Date', stamp(DATE)]
    ]);
});

test('the Russian build reads the same rows in Russian', () => {
    const ctx = load(makeHost(), 'ru-RU');
    const rows = details(ctx, BASE);
    assert.deepStrictEqual(titleValuePairs(rows), [
        ['ID', '4242'],
        ['Дата', stamp(DATE)]
    ]);
});

test('views and shares come first, and only when non-zero', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, { views: 15, forwards: 3 }));
    assert.deepStrictEqual(titleValuePairs(rows).slice(0, 2), [
        ['Views', '15'],
        ['Shares', '3']
    ]);

    const none = details(ctx, Object.assign({}, BASE, { views: 0, forwards: 0 }));
    assert.strictEqual(find(none, 'Views'), undefined);
    assert.strictEqual(find(none, 'Shares'), undefined);
});

test('the sticker set id sits directly after the id', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'sticker',
        media: { mime: 'application/x-tgsticker', sticker_pack: { id: 987654 } }
    }));
    const titles = rows.map((row) => row.title);
    assert.strictEqual(titles.indexOf('Sticker Set ID'), titles.indexOf('ID') + 1);
    assert.strictEqual(find(rows, 'Sticker Set ID').value, '987654');
});

test('a forwarded date is skipped when it equals the message date', () => {
    const ctx = load(makeHost());
    const same = details(ctx, Object.assign({}, BASE, {
        forwarded: { date: BASE.date }
    }));
    assert.strictEqual(find(same, 'Forwarded Date'), undefined);

    const earlier = details(ctx, Object.assign({}, BASE, {
        forwarded: { date: BASE.date - 3600 }
    }));
    assert.strictEqual(find(earlier, 'Forwarded Date').value, stamp(BASE.date - 3600));
});

test('a hidden or equal edit date produces no row', () => {
    const ctx = load(makeHost());
    assert.strictEqual(find(details(ctx, Object.assign({}, BASE, { edit_date: BASE.date })), 'Edited Date'), undefined);
    const edited = details(ctx, Object.assign({}, BASE, { edit_date: BASE.date + 60 }));
    assert.strictEqual(find(edited, 'Edited Date').value, stamp(BASE.date + 60));
});

test('the delete date comes from the expiration the host computed', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, { autoremove_expires: BASE.date + 86400 }));
    assert.strictEqual(find(rows, 'Delete Date').value, stamp(BASE.date + 86400));
});

test('a music track reports its size, type, metadata and bitrate', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'music',
        media: {
            mime: 'audio/mpeg',
            size: 4000000,
            duration: 256,
            title: 'Song',
            performer: 'Artist',
            waveform_length: 63
        }
    }));
    assert.strictEqual(find(rows, 'File Size').value, '3.8 MB');
    assert.strictEqual(find(rows, 'Audio Type').value, 'Music Track');
    assert.strictEqual(find(rows, 'Mime Type').value, 'audio/mpeg');
    assert.strictEqual(find(rows, 'Artists').value, 'Artist');
    assert.strictEqual(find(rows, 'Title').value, 'Song');
    assert.strictEqual(find(rows, 'Duration').value, '04:16');
    // 4,000,000 bytes * 8 / 256 s / 1000 = 125 Kbps
    assert.strictEqual(find(rows, 'Bitrate').value, '125 Kbps');
    assert.strictEqual(find(rows, 'Compression Mode').value, 'Lossy');
    assert.strictEqual(find(rows, 'Waveform Length').value, '63');
    assert.strictEqual(find(rows, 'Stream Size').value, '3.8 MB');
});

test('a voice note is labelled as one and a flac is lossless', () => {
    const ctx = load(makeHost());
    const voice = details(ctx, Object.assign({}, BASE, {
        media_kind: 'voice',
        media: { mime: 'audio/ogg', size: 20000, duration: 12, is_voice: true }
    }));
    assert.strictEqual(find(voice, 'Audio Type').value, 'Voice Note');
    assert.strictEqual(find(voice, 'Compression Mode').value, 'Lossy');

    const flac = details(ctx, Object.assign({}, BASE, {
        media_kind: 'music',
        media: { mime: 'audio/flac', size: 90000000, duration: 300 }
    }));
    assert.strictEqual(find(flac, 'Compression Mode').value, 'Lossless');
});

test('sample rate, channels and bit depth print in their own units', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'music',
        media: { mime: 'audio/flac', size: 1000, duration: 10, sample_rate: 44100, channels: 2, bit_depth: 24 }
    }));
    assert.strictEqual(find(rows, 'Sample Rate').value, '44.1 kHz');
    assert.strictEqual(find(rows, 'Channels').value, 'Stereo');
    assert.strictEqual(find(rows, 'Bit Depth').value, '24 bit');

    const mono = details(ctx, Object.assign({}, BASE, {
        media_kind: 'music',
        media: { mime: 'audio/mpeg', size: 1000, duration: 10, sample_rate: 48000, channels: 1 }
    }));
    assert.strictEqual(find(mono, 'Sample Rate').value, '48 kHz');
    assert.strictEqual(find(mono, 'Channels').value, 'Mono');
});

test('a round video, a gif and a plain video are named differently', () => {
    const ctx = load(makeHost());
    const media = { mime: 'video/mp4', size: 1000000, duration: 30, width: 720, height: 1280 };
    const plain = details(ctx, Object.assign({}, BASE, { media_kind: 'video', media }));
    assert.strictEqual(find(plain, 'Video Type').value, 'Video');
    assert.strictEqual(find(plain, 'Resolution').value, '720x1280');

    const round = details(ctx, Object.assign({}, BASE, { media_kind: 'round_video', media }));
    assert.strictEqual(find(round, 'Video Type').value, 'Video Note');

    const gif = details(ctx, Object.assign({}, BASE, { media_kind: 'gif', media }));
    assert.strictEqual(find(gif, 'Video Type').value, 'Animated GIF');
});

test('a video with streaming support says so, and without it says nothing', () => {
    const ctx = load(makeHost());
    const media = { mime: 'video/mp4', size: 900000, duration: 20, width: 640, height: 480 };
    const off = details(ctx, Object.assign({}, BASE, { media_kind: 'video', media }));
    assert.strictEqual(find(off, 'Streaming Support'), undefined);

    const on = details(ctx, Object.assign({}, BASE, {
        media_kind: 'video',
        media: Object.assign({}, media, { supports_streaming: true, codec: 'h264', fps: 30 })
    }));
    assert.strictEqual(find(on, 'Streaming Support').value, 'Yes');
    assert.strictEqual(find(on, 'Video Codec').value, 'h264');
    assert.strictEqual(find(on, 'FPS').value, '30 FPS');
});

test('stickers say which kind they are and where they come from', () => {
    const ctx = load(makeHost());
    const animated = details(ctx, Object.assign({}, BASE, {
        media_kind: 'sticker_animated',
        media: {
            mime: 'application/x-tgsticker',
            sticker_pack: { short_name: 'ducks', id: 77, index: 3 },
            emoji: '🦆'
        }
    }));
    assert.strictEqual(find(animated, 'Video Type').value, 'Animated Sticker');
    assert.strictEqual(find(animated, 'Sticker Pack').value, 'ducks/3');
    assert.strictEqual(find(animated, 'Associated Emoji').value, '🦆');

    const video = details(ctx, Object.assign({}, BASE, {
        media_kind: 'sticker_video',
        media: { mime: 'video/webm', sticker_pack: { short_name: 'cats' } }
    }));
    assert.strictEqual(find(video, 'Video Type').value, 'Video Sticker');
    assert.strictEqual(find(video, 'Sticker Pack').value, 'cats');

    const plain = details(ctx, Object.assign({}, BASE, {
        media_kind: 'sticker',
        media: { mime: 'image/webp' }
    }));
    assert.strictEqual(find(plain, 'Video Type').value, 'Static Sticker');
    assert.strictEqual(find(plain, 'Sticker Pack'), undefined);
});

test('a custom emoji reports its adaptive text colour only when it has one', () => {
    const ctx = load(makeHost());
    const adaptive = details(ctx, Object.assign({}, BASE, {
        media_kind: 'custom_emoji',
        media: { mime: 'application/x-tgsticker', emoji: '🔥', adaptive_text_color: true }
    }));
    assert.strictEqual(find(adaptive, 'Video Type').value, 'Custom Emoji');
    assert.strictEqual(find(adaptive, 'Adaptive Text Color').value, 'Yes');

    const plain = details(ctx, Object.assign({}, BASE, {
        media_kind: 'custom_emoji',
        media: { mime: 'application/x-tgsticker', emoji: '🔥' }
    }));
    assert.strictEqual(find(plain, 'Adaptive Text Color'), undefined);
});

test('a poll lists every one of its switches', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'poll',
        media: {
            poll: {
                question: 'Best colour?',
                is_closed: false,
                public_voters: true,
                multiple_choice: true,
                add_options: false,
                allow_revoting: true,
                shuffle_options: false,
                quiz: true,
                duration_limit: 3600,
                close_date: BASE.date + 3600,
                total_voters: 42
            }
        }
    }));
    assert.strictEqual(find(rows, 'Poll Question').value, 'Best colour?');
    assert.strictEqual(find(rows, 'Show Who Voted').value, 'Yes');
    assert.strictEqual(find(rows, 'Allow Multiple Answers').value, 'Yes');
    assert.strictEqual(find(rows, 'Allow Adding Options').value, 'No');
    assert.strictEqual(find(rows, 'Allow Revoting').value, 'Yes');
    assert.strictEqual(find(rows, 'Shuffle Options').value, 'No');
    assert.strictEqual(find(rows, 'Quiz Mode').value, 'Yes');
    assert.strictEqual(find(rows, 'Limit Duration').value, '01:00:00');
    assert.strictEqual(find(rows, 'Auto-Close Date').value, stamp(BASE.date + 3600));
    assert.strictEqual(find(rows, 'Poll Status').value, 'Open');
    assert.strictEqual(find(rows, 'Total Voters').value, '42');
});

test('a closed poll says so, and a missing voter count is omitted', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'poll',
        media: { poll: { question: 'Q', is_closed: true, total_voters: 0 } }
    }));
    assert.strictEqual(find(rows, 'Poll Status').value, 'Closed');
    assert.strictEqual(find(rows, 'Total Voters'), undefined);
    assert.strictEqual(find(rows, 'Allow Revoting').value, 'No');
});

test('a service message reports its action', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'service',
        media: { action: 'added_members' }
    }));
    assert.strictEqual(find(rows, 'Service Action').value, 'added_members');
});

test('the datacenter comes last', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'photo',
        media: { mime: 'image/jpeg', width: 1280, height: 720, dc_id: 4, size: 200000 }
    }));
    assert.deepStrictEqual(titleValuePairs(rows).slice(-1), [['Datacenter', 'DC4']]);
    assert.strictEqual(find(rows, 'Resolution').value, '1280x720');
    assert.strictEqual(find(rows, 'File Size').value, '195.3 KB');
});

test('a photo in a document shows its file name', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'photo_file',
        media: { mime: 'image/png', width: 100, height: 100, file_name: 'shot.png' }
    }));
    assert.strictEqual(find(rows, 'File Name').value, 'shot.png');
});

test('an empty value never produces a row', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, {
        media_kind: 'music',
        media: { mime: '', size: 0, duration: 0, title: '', performer: '' }
    }));
    for (const row of rows) {
        assert.notStrictEqual(row.value, '', row.title);
    }
});

test('the scheduled-message timestamp reads as "When Online"', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, Object.assign({}, BASE, { date: 2147483646 }));
    assert.strictEqual(find(rows, 'Date').value, 'When Online');
});

test('a malformed message yields an array, not a throw', () => {
    const ctx = load(makeHost());
    assert.deepStrictEqual(details(ctx, null), []);
    // The id is appended unconditionally by the original, so a message with
    // nothing else still has one row.
    assert.deepStrictEqual(titleValuePairs(details(ctx, { id: 1, date: 0 })), [['ID', '1']]);
});

test('a message with no media has no media rows', () => {
    const ctx = load(makeHost());
    const rows = details(ctx, BASE);
    for (const title of ['File Size', 'Mime Type', 'Resolution', 'Datacenter', 'Duration']) {
        assert.strictEqual(find(rows, title), undefined, title);
    }
});

test('the settings screen explains the menu item without a stored setting', () => {
    const ctx = load(makeHost());
    const controls = settingsOf(ctx);
    const interactive = controls.filter((control) =>
        control.type === 'switch' || control.type === 'selector' || control.type === 'input');
    assert.strictEqual(interactive.length, 0, 'the original has no switches');
    assert.ok(controls.some((control) => control.type === 'text'));
    // `Header(...)` takes an options object; a bare string leaves `text` empty
    // and the screen shows a blank separator instead of the section title.
    const headers = controls.filter((control) => control.type === 'header');
    assert.ok(headers.length > 0, 'the screen has a section header');
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