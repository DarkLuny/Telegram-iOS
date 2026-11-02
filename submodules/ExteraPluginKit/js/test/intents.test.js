/*
 * The `intents` module: registering global before/after handlers for URLs,
 * matching them by scheme/host/path/query, and stopping the original handling.
 * `node js/test/intents.test.js`.
 *
 * The Swift host in `AppDelegate.handleOpenURL` calls
 * `__extera.dispatchUrlIntent` before it opens a URL and
 * `__extera.dispatchUrlIntentAfter` once it has, so these two entry points are
 * the contract between the module and the client.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const bootstrap = fs.readFileSync(path.join(__dirname, '..', 'bootstrap.js'), 'utf8');

function makeHost() {
    const calls = [];
    return {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: () => null,
        setSetting: () => undefined,
        appVersion: () => '13.1.1',
        pluginDirectory: () => '/plugins/demo',
        selectedAccount: () => 42,
    };
}

function runPlugin(source, host) {
    const context = vm.createContext({ __host: host, console });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext('__extera.setIdentity("demo", "Demo")', context);
    vm.runInContext(source, context, { filename: 'demo.plugin.js' });
    return context;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('parse splits a deeplink into scheme, host, path and query', () => {
    const ctx = runPlugin(`
        var parts = intents.IntentsManager.parse("tg://chat?id=123");
        var withPath = intents.IntentsManager.parse("https://t.me/user/42?ref=1");
    `, makeHost());
    assert.strictEqual(ctx.parts.scheme, 'tg');
    assert.strictEqual(ctx.parts.host, 'chat');
    assert.strictEqual(ctx.parts.query, 'id=123');
    assert.strictEqual(ctx.withPath.host, 't.me');
    assert.strictEqual(ctx.withPath.path, '/user/42');
    assert.strictEqual(ctx.withPath.query, 'ref=1');
});

test('a before-handler runs for a matching scheme and host, and its return stops the URL', () => {
    const ctx = runPlugin(`
        var seen = null;
        var handle = intents.IntentsManager.new_global_before_handler(function (host, id) {
            seen = { host: host, id: id };
            return true;
        }, { scheme: "tg", host: "chat", required_path_args_names: ["id"] });
        var stopped = __extera.dispatchUrlIntent("tg://chat?id=123");
        var unmatched = __extera.dispatchUrlIntent("tg://profile?user=1");
    `, makeHost());
    assert.strictEqual(ctx.stopped, true);
    assert.strictEqual(ctx.seen.host, 'chat');
    assert.strictEqual(ctx.seen.id, '123');
    assert.strictEqual(ctx.unmatched, false);
});

test('a matching handler that returns nothing does not stop the URL', () => {
    const ctx = runPlugin(`
        var called = false;
        intents.IntentsManager.new_global_before_handler(function () {
            called = true;
        }, { scheme: "tg" });
        var stopped = __extera.dispatchUrlIntent("tg://chat?id=1");
    `, makeHost());
    assert.strictEqual(ctx.called, true);
    assert.strictEqual(ctx.stopped, false);
});

test('handlers run in ascending priority, and the first stop short-circuits', () => {
    const ctx = runPlugin(`
        var order = [];
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("late");
        }, { scheme: "tg", priority: 10 });
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("early");
            return true;
        }, { scheme: "tg", priority: 0 });
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("never");
        }, { scheme: "tg", priority: 20 });
        var stopped = __extera.dispatchUrlIntent("tg://chat");
    `, makeHost());
    // The SDK stops after a handler returns true, so the lower-priority one that
    // runs first and returns true is the last that runs.
    assert.deepStrictEqual(Array.from(ctx.order), ['early']);
    assert.strictEqual(ctx.stopped, true);
});

test('without a stop, every matching handler runs in ascending priority', () => {
    const ctx = runPlugin(`
        var order = [];
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("third");
        }, { scheme: "tg", priority: 30 });
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("first");
        }, { scheme: "tg", priority: 10 });
        intents.IntentsManager.new_global_before_handler(function () {
            order.push("second");
        }, { scheme: "tg", priority: 20 });
        __extera.dispatchUrlIntent("tg://chat");
    `, makeHost());
    assert.deepStrictEqual(Array.from(ctx.order), ['first', 'second', 'third']);
});

test('an after-handler runs once the URL has been handled and cannot stop it', () => {
    const ctx = runPlugin(`
        var afterRan = null;
        intents.IntentsManager.new_global_after_handler(function (host) {
            afterRan = host;
            return true;
        }, { scheme: "https", host: "t.me" });
        __extera.dispatchUrlIntentAfter("https://t.me/joinchat/abc");
        var beforeStopped = __extera.dispatchUrlIntent("https://t.me/joinchat/abc");
    `, makeHost());
    assert.strictEqual(ctx.afterRan, 't.me');
    // An after-handler returning true changes nothing about the before pass.
    assert.strictEqual(ctx.beforeStopped, false);
});

test('a path template exposes its variables to the callback', () => {
    const ctx = runPlugin(`
        var captured = null;
        intents.IntentsManager.new_global_before_handler(function (user_id, path) {
            captured = { user_id: user_id, path: path };
        }, { scheme: "tg", host: "profile", path: "/user/{user_id}" });
        __extera.dispatchUrlIntent("tg://profile/user/987");
        __extera.dispatchUrlIntent("tg://profile/user");
    `, makeHost());
    assert.strictEqual(ctx.captured.user_id, '987');
    assert.strictEqual(ctx.captured.path, '/user/987');
});

test('a required query argument that is missing skips the handler', () => {
    const ctx = runPlugin(`
        var hits = 0;
        intents.IntentsManager.new_global_before_handler(function () {
            hits += 1;
        }, { scheme: "tg", host: "chat", required_path_args_names: ["id"] });
        __extera.dispatchUrlIntent("tg://chat?id=123");
        __extera.dispatchUrlIntent("tg://chat");
    `, makeHost());
    assert.strictEqual(ctx.hits, 1);
});

test('unhandle removes a handler, and unhandling an unknown id raises HandlerNotRegistered', () => {
    const ctx = runPlugin(`
        var hits = 0;
        var handle = intents.IntentsManager.new_global_before_handler(function () {
            hits += 1;
        }, { scheme: "tg" });
        __extera.dispatchUrlIntent("tg://chat");
        handle.unhandle();
        __extera.dispatchUrlIntent("tg://chat");
        var raised = null;
        try {
            intents.IntentsManager.unhandle("intent_does_not_exist");
        } catch (error) {
            raised = error.name;
        }
    `, makeHost());
    assert.strictEqual(ctx.hits, 1);
    assert.strictEqual(ctx.raised, 'HandlerNotRegistered');
});

test('unhandle by id removes the same handler the handle named', () => {
    const ctx = runPlugin(`
        var hits = 0;
        var handle = intents.IntentsManager.new_global_before_handler(function () {
            hits += 1;
        }, { scheme: "tg" });
        intents.IntentsManager.unhandle(handle.handler_id);
        __extera.dispatchUrlIntent("tg://chat");
    `, makeHost());
    assert.strictEqual(ctx.hits, 0);
});

test('a throwing handler is logged and the URL is not treated as stopped', () => {
    const host = makeHost();
    const ctx = runPlugin(`
        intents.IntentsManager.new_global_before_handler(function () {
            throw new Error("boom");
        }, { scheme: "tg" });
        var stopped = __extera.dispatchUrlIntent("tg://chat");
    `, host);
    assert.strictEqual(ctx.stopped, false);
    assert.ok(host.calls.some(c => c[0] === 'log' && /intent before-handler threw/.test(c[2])));
});

test('the action treats an opened link as ACTION_VIEW, so a plugin can compare', () => {
    const ctx = runPlugin(`
        var seen = null;
        intents.IntentsManager.new_global_before_handler(function (action) {
            seen = action;
        }, { scheme: "tg" });
        __extera.dispatchUrlIntent("tg://chat");
        var view = intents.Intent.ACTION_VIEW;
    `, makeHost());
    assert.strictEqual(ctx.seen, 'android.intent.action.VIEW');
    assert.strictEqual(ctx.view, 'android.intent.action.VIEW');
});

let failed = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (error) {
        failed += 1;
        console.log('FAIL ' + name);
        console.log('     ' + (error && error.message));
    }
}
console.log('');
console.log((tests.length - failed) + '/' + tests.length + ' passed');
if (failed > 0) {
    process.exitCode = 1;
}
