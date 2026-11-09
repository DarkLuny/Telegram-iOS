/*
 * The gap-closure surface: hook priorities, the extended send/edit options,
 * the structured logger (`self.logger` / `log_utils`), the full `HookFilter`
 * set with `MethodReplacement`, unhook tokens, and the MVEL subset translator.
 * `node js/test/gap.test.js`.
 *
 * The Swift side of each item (chain ordering by priority in `dispatch`, the
 * schedule/spoiler attributes, the manifest categories, the palette slots)
 * lives in `ExteraPluginKit` and `TelegramCore`; what this file pins is the
 * JavaScript contract the Swift host consumes, which is the part the fake
 * `__host` below has to answer for.
 *
 * The lifecycle runs the way `PluginManager` runs it: `finalize` first, then
 * `on_plugin_load`, so a plugin's registrations and sends happen in the test
 * body rather than at class-body level.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const bootstrap = fs.readFileSync(path.join(__dirname, '..', 'bootstrap.js'), 'utf8');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The host as the Swift side presents it, with the two shapes this file is
// about: `addHook`/`addOnSendMessageHook` now carry the priority, and
// `removeSwizzle` answers `unhook_method`. `installSwizzle` records the token
// pair so a test can drive the callbacks the way `PluginSwizzle` does.
const BEFORE_TOKEN = 4;
const AFTER_TOKEN = 5;

function makeHost() {
    const calls = [];
    const swizzles = new Set();
    const host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: () => null,
        setSetting: () => undefined,
        exportSettings: () => ({}),
        importSettings: () => undefined,
        addHook: (id, name, matchSubstring, priority) => calls.push(['addHook', id, name, !!matchSubstring, priority || 0]),
        addOnSendMessageHook: (id, priority) => calls.push(['addOnSendMessageHook', id, priority || 0]),
        addMenuItem: () => 'item',
        removeMenuItem: () => undefined,
        sendText: (id, account, peerId, text, opts) => calls.push(['sendText', id, account, peerId, text, JSON.parse(opts || '{}')]),
        sendFile: (id, account, kind, peerId, p, opts) => calls.push(['sendFile', id, account, kind, peerId, p, JSON.parse(opts || '{}')]),
        editMessage: (id, account, peerId, msgId, text, opts) => calls.push(['editMessage', id, account, peerId, msgId, text, JSON.parse(opts || '{}')]),
        showBulletin: () => undefined,
        showAlert: () => undefined,
        dismissAlert: () => undefined,
        fileOp: () => JSON.stringify(null),
        selectedAccount: () => 42,
        appVersion: () => '13.1.1',
        pluginDirectory: () => '/plugins/demo',
        schedulePlugin: () => undefined,
        copyToClipboard: () => undefined,
        openUrl: () => true,
        classExists: () => true,
        installSwizzle: (pluginId, className, selector, isClassMethod, beforeToken, afterToken) => {
            calls.push(['installSwizzle', className, selector, isClassMethod, beforeToken, afterToken]);
            swizzles.add(className + '.' + selector + ':' + (isClassMethod ? 'c' : 'i'));
            return null;
        },
        removeSwizzle: (pluginId, className, selector, isClassMethod) => {
            calls.push(['removeSwizzle', className, selector, isClassMethod]);
            return swizzles.delete(className + '.' + selector + ':' + (isClassMethod ? 'c' : 'i'));
        },
    };
    return host;
}

function runPlugin(source, host) {
    const context = vm.createContext({ __host: host, console, JSON });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext('__extera.setIdentity("demo", "Demo")', context);
    vm.runInContext(source, context, { filename: 'demo.plugin.js' });
    vm.runInContext('__extera.finalize()', context);
    vm.runInContext('__extera.callLifecycle(__extera.instance, "on_plugin_load", [])', context);
    return context;
}

function logs(host) {
    return host.calls.filter((entry) => entry[0] === 'log').map((entry) => entry[2]);
}

test('hook priorities reach the host in both spellings', () => {
    const host = makeHost();
    runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                this.add_hook("messages.setTyping", false, 10);
                this.add_hook("messages.", true, 3);
                this.add_hook("account.updateStatus");
                this.add_on_send_message_hook(7);
            }
        }
    `, host);
    assert.deepEqual(host.calls.filter((entry) => entry[0] === 'addHook'), [
        ['addHook', 'demo', 'messages.setTyping', false, 10],
        ['addHook', 'demo', 'messages.', true, 3],
        ['addHook', 'demo', 'account.updateStatus', false, 0],
    ]);
    assert.deepEqual(
        host.calls.filter((entry) => entry[0] === 'addOnSendMessageHook'),
        [['addOnSendMessageHook', 'demo', 7]]
    );
});

test('unhook_method removes the swizzle and reports honestly', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                var cls = hook_utils.find_class("DemoClass");
                var token = cls.hook("demoSelector", new MethodHook());
                this.first = this.unhook_method(token);
                this.second = this.unhook_method(token);
                this.third = this.unhook_method(null);
            }
        }
    `, host);
    assert.strictEqual(context.__extera.instance.first, true);
    // The pair is gone, so a second unhook has nothing to remove.
    assert.strictEqual(context.__extera.instance.second, false);
    assert.strictEqual(context.__extera.instance.third, false);
    // Both calls reach the host; the second one is answered false there.
    assert.equal(host.calls.filter((entry) => entry[0] === 'removeSwizzle').length, 2);
});

test('send_message carries scheduleDate, hasMediaSpoilers and refuses ttl out loud', () => {
    const host = makeHost();
    runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                this.send_message({ peer: 10, message: "later", scheduleDate: 1893456000, hasMediaSpoilers: true, ttl: 30 });
                this.send_message({ peer: 10, message: "plain", schedule_date: 1893456001, has_media_spoilers: true });
                this.send_photo(10, "/tmp/a.png", { caption: "cap", scheduleDate: 1893456002, with_spoiler: true });
            }
        }
    `, host);
    const texts = host.calls.filter((entry) => entry[0] === 'sendText').map((entry) => entry[5]);
    assert.strictEqual(texts[0].scheduleDate, 1893456000);
    assert.strictEqual(texts[0].hasMediaSpoilers, true);
    // The dict form accepts the snake_case spelling a Python port carried.
    assert.strictEqual(texts[1].scheduleDate, 1893456001);
    assert.strictEqual(texts[1].hasMediaSpoilers, true);
    assert.ok(logs(host).some((line) => line.includes('ttl is not supported')), 'the ttl refusal must be logged');
    // A typed helper passes its options through untouched, so the same keys
    // arrive from there without the bootstrap mapping anything.
    const file = host.calls.find((entry) => entry[0] === 'sendFile');
    assert.strictEqual(file[6].scheduleDate, 1893456002);
    assert.strictEqual(file[6].with_spoiler, true);
});

test('edit_message maps file_path to the bridge options and warns about with_spoiler', () => {
    const host = makeHost();
    runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                this.edit_message({ peer: 10, id: 5 }, "new caption", { file_path: "/tmp/a.png", photo: true, with_spoiler: true, parse_mode: "html" });
                this.edit_message({ peer: 10, id: 6 }, "text only", {});
            }
        }
    `, host);
    const edits = host.calls.filter((entry) => entry[0] === 'editMessage');
    assert.strictEqual(edits[0][6].file_path, '/tmp/a.png');
    assert.strictEqual(edits[0][6].file_kind, 'photo');
    assert.strictEqual(edits[1][6].file_path, undefined);
    assert.ok(logs(host).some((line) => line.includes('with_spoiler has no effect')), 'the with_spoiler note must be logged');
});

test('the logger filters by level and formats lazily', () => {
    const host = makeHost();
    runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                this.logger.debug("should not appear: %s", "hidden");
                this.logger.info("chat %s: %s", 5, "active");
                this.logger.level = "debug";
                this.logger.debug("now visible: %d and %f", 3.7, 2.5);
                this.logger.level = null;
                this.logger.debug("off again");
                this.logger.warning("careful");
                this.logger.error("request failed", { stack: "at demo.plugin.js:1" });
                this.logger.exception(new Error("boom"));
            }
        }
    `, host);
    const lines = logs(host).filter((line) => line.includes('plugin.demo'));
    assert.ok(!lines.some((line) => line.includes('should not appear')), 'DEBUG is off by default');
    assert.ok(lines.some((line) => line.includes('[INFO] plugin.demo: chat 5: active')));
    assert.ok(lines.some((line) => line.includes('[DEBUG] plugin.demo: now visible: 3 and 2.5')), '%d truncates and %f keeps the float');
    assert.ok(!lines.some((line) => line.includes('off again')), 'level = null restores the default');
    assert.ok(lines.some((line) => line.includes('[WARNING] plugin.demo: careful')));
    const errorLine = lines.find((line) => line.includes('request failed'));
    assert.ok(errorLine.includes('at demo.plugin.js:1'), 'exc_info stack rides the same line');
    const exceptionLine = lines.find((line) => line.includes('boom'));
    assert.ok(exceptionLine.includes('[ERROR]') && exceptionLine.includes('Error: boom'), 'exception() renders the message and stack');
});

test('children inherit the threshold, handlers see the record shape', () => {
    const host = makeHost();
    const context = runPlugin(`
        var window_records;
        class Plugin extends BasePlugin {
            on_plugin_load() {
                var records = [];
                this.logger.add_handler(function (record) { records.push(record); });
                var net = this.logger.child("net");
                net.debug("quiet");
                net.info("listening");
                net.level = LogLevel.DEBUG;
                net.debug("loud");
                window_records = records;
            }
        }
    `, host);
    const records = vm.runInContext('window_records', context);
    assert.deepEqual(records.map((record) => record.message), ['listening', 'loud']);
    assert.strictEqual(records[0].tag, 'plugin.demo.net');
    assert.strictEqual(records[0].level, 'INFO');
    assert.strictEqual(records[0].traceback, null);
    assert.ok(typeof records[0].created === 'number');
    assert.ok(records[0].text.includes('[INFO] plugin.demo.net: listening'));
});

test('dump marks cycles, caps arrays and is a pure function in log_utils', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                var value = { name: "outer", self: null, list: [1, 2, 3, 4, 5] };
                value.self = value;
                this.plain = log_utils.dump(value, "value", 2, 3);
                this.logger.level = LogLevel.DEBUG;
                this.logger.dump(value, "through the logger", 2, 3);
            }
        }
    `, host);
    const instance = context.__extera.instance;
    assert.ok(instance.plain.includes('value: {'), 'the label prefixes the dump');
    assert.ok(instance.plain.includes('<cycle>'), 'a self-reference is marked, not walked');
    assert.ok(instance.plain.includes('Array(5) [1, 2, 3, + 2 more]'), 'arrays are capped with a remainder count');
    const loggerLine = logs(host).find((line) => line.includes('through the logger'));
    assert.ok(loggerLine.includes('[DEBUG]'), 'logger.dump logs at DEBUG');
    assert.ok(loggerLine.includes('<cycle>'));
});

test('timed reports the duration and the failed variant', () => {
    const host = makeHost();
    runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                this.logger.level = LogLevel.DEBUG;
                var timer = this.logger.timed("sync");
                timer.end();
                var failing = this.logger.timed("flaky");
                failing.end(true);
            }
        }
    `, host);
    assert.ok(logs(host).some((line) => /sync took \d+ ms/.test(line)));
    assert.ok(logs(host).some((line) => /flaky \(failed\) took \d+ ms/.test(line)));
});

test('log_utils exposes get_logger and the LogLevel constants', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {
            on_plugin_load() {
                var helper = get_logger("helper");
                helper.info("from the helper module");
            }
        }
    `, host);
    assert.ok(logs(host).some((line) => line.includes('[INFO] plugin.demo.helper: from the helper module')));
    assert.strictEqual(context.LogLevel.DEBUG, 20);
    assert.strictEqual(context.LogLevel.OFF, 100);
    assert.strictEqual(typeof context.dump, 'function');
});

test('before_filters gate the callback without freezing the original', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {}
        var hook = new MethodHook();
        hook.beforeHookedMethod = function (param) { param.setResult("before:" + param.getArg(0)); };
        hook_utils.find_class("DemoClass").hook("demoSelector", hook, undefined, {
            before_filters: [HookFilter.ArgumentNotNull(0)],
        });
    `, host);
    const record = host.calls.find((entry) => entry[0] === 'installSwizzle');
    assert.ok(record, 'the hook must reach the host');
    // The filter passes: the before hook runs and its result is the replacement.
    const pass = context.__extera.runSwizzleCallback(record[BEFORE_TOKEN], 'receiver', '["x"]', null);
    assert.strictEqual(pass, '"before:x"');
    // The filter rejects: the callback is skipped, so the answer is null and
    // the host runs the original method.
    const reject = context.__extera.runSwizzleCallback(record[BEFORE_TOKEN], 'receiver', '[null]', null);
    assert.strictEqual(reject, null);
});

test('MethodReplacement supplies the whole implementation through before', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {}
        var replacement = new MethodReplacement();
        replacement.replace_hooked_method = function (param) { return "replaced:" + param.getArg(0); };
        hook_utils.find_class("DemoClass").hook("demoSelector", replacement);
    `, host);
    const record = host.calls.find((entry) => entry[0] === 'installSwizzle');
    assert.ok(record, 'the hook must reach the host');
    assert.strictEqual(record[AFTER_TOKEN], null, 'a replacement has no after phase');
    const answer = context.__extera.runSwizzleCallback(record[BEFORE_TOKEN], 'receiver', '["in"]', null);
    assert.strictEqual(answer, '"replaced:in"');
});

test('the full HookFilter set answers as predicates', () => {
    const host = makeHost();
    const context = runPlugin(`
        class Plugin extends BasePlugin {}
        var window_results;
        var paramLike = function (args, result) {
            return {
                args: args,
                getArg: function (i) { return args[i]; },
                getResult: function () { return result; },
            };
        };
        var p = paramLike([null, "value", true, 5], null);
        var results = {};
        results.result_null = HookFilter.RESULT_IS_NULL(p);
        results.result_not_null = HookFilter.RESULT_NOT_NULL(p);
        results.arg_null = HookFilter.ArgumentIsNull(0)(p);
        results.arg_not_null = HookFilter.ArgumentNotNull(1)(p);
        results.arg_true = HookFilter.ArgumentIsTrue(2)(p);
        results.arg_equal = HookFilter.ArgumentEqual(3, 5)(p);
        results.arg_not_equal = HookFilter.ArgumentNotEqual(3, 6)(p);
        results.condition_pass = HookFilter.Condition("param.getArg(1) contains 'alu' || object == 500", 500)(p);
        results.condition_reject = HookFilter.Condition("param.getArg(1) contains 'zzz'", null)(p);
        results.condition_mvel = HookFilter.Condition("param.getArg(1) contains 'alue' && isdef object", null)(p);
        results.or_pass = HookFilter.Or(HookFilter.ArgumentIsNull(9), HookFilter.ArgumentIsTrue(2))(p);
        results.or_reject = HookFilter.Or(HookFilter.ArgumentIsNull(9), HookFilter.ArgumentIsNull(2))(p);
        results.instanceof = HookFilter.Condition("param.getArg(1) instanceof android.view.View")(p);
        window_results = results;
    `, host);
    const results = vm.runInContext('window_results', context);
    assert.strictEqual(results.result_null, true);
    assert.strictEqual(results.result_not_null, false);
    assert.strictEqual(results.arg_null, true);
    assert.strictEqual(results.arg_not_null, true);
    assert.strictEqual(results.arg_true, true);
    assert.strictEqual(results.arg_equal, true);
    assert.strictEqual(results.arg_not_equal, true);
    assert.strictEqual(results.condition_pass, true);
    assert.strictEqual(results.condition_reject, false);
    assert.strictEqual(results.condition_mvel, true);
    assert.strictEqual(results.or_pass, true);
    assert.strictEqual(results.or_reject, false);
    assert.strictEqual(results.instanceof, false);
    assert.ok(logs(host).some((line) => line.includes('instanceof has no iOS equivalent')), 'the instanceof limit is said once');
});

test('translateMVEL covers the documented subset', () => {
    const host = makeHost();
    const context = runPlugin('class Plugin extends BasePlugin {}', host);
    const t = (expression) => vm.runInContext('translateMVEL(' + JSON.stringify(expression) + ')', context);
    assert.strictEqual(t("name contains 'el'"), "name.indexOf('el') >= 0");
    assert.strictEqual(t('a contains "b"'), 'a.indexOf("b") >= 0');
    assert.strictEqual(t('x instanceof android.view.View'), 'false');
    assert.strictEqual(t('isdef dialog_id && dialog_id > 0'), 'dialog_id !== undefined && dialog_id > 0');
    assert.strictEqual(t('undef gone'), 'gone === undefined');
    assert.strictEqual(t('dialog_id > 0 && dialog_id != 1000'), 'dialog_id > 0 && dialog_id != 1000');
    // Plain JavaScript passes through unchanged.
    assert.strictEqual(t('a.b.c == 7'), 'a.b.c == 7');
});

let failed = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed += 1;
        console.log('FAIL ' + name + ': ' + error.message);
    }
}
if (failed) {
    process.exit(1);
}
console.log(tests.length + ' tests, ' + failed + ' failed');
