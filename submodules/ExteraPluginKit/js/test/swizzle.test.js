/*
 * The swizzle bridge: the Xposed-shaped hook API over `MethodHook`, and the
 * contract the Swift side relies on.
 * `node js/test/swizzle.test.js`.
 *
 * `PluginSwizzle` calls `__extera.runSwizzleCallback(token, receiver, argsJSON,
 * resultJSON)` and treats a non-null answer as "the plugin replaced the method's
 * result". Everything below holds that line: a `before` hook that sets nothing
 * must answer null so the original runs; an `after` hook must be able to *read*
 * the original result without that reading counting as a replacement.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const bootstrap = fs.readFileSync(path.join(__dirname, '..', 'bootstrap.js'), 'utf8');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The host as the Swift side presents it, plus a recorder so a test can reach the
// tokens `installHook` registered. The order of the `installSwizzle` arguments is
// the signature in `PluginLoader`:
//   (pluginId, className, selector, isClassMethod, beforeToken, afterToken)
// so the tokens sit at indexes 4 and 5.
const BEFORE_TOKEN = 4;
const AFTER_TOKEN = 5;

function makeHost() {
    const calls = [];
    const host = {
        calls,
        log: (id, text) => calls.push(['log', id, text]),
        getSetting: () => null,
        setSetting: () => undefined,
        appVersion: () => '13.1.1',
        pluginDirectory: () => '/plugins/demo',
        selectedAccount: () => 42,
        // `find_class` asks the host whether the class is loaded before it builds
        // a handle; without this the hook path answers null and a test would be
        // exercising the "not found" branch instead of the hook.
        classExists: () => true,
        installSwizzle: (pluginId, className, selector, isClassMethod, beforeToken, afterToken) => {
            calls.push(['installSwizzle', className, selector, isClassMethod, beforeToken, afterToken]);
            return null;
        },
    };
    return host;
}

function runPlugin(source, host) {
    const context = vm.createContext({ __host: host, console, JSON });
    vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
    vm.runInContext('__extera.setIdentity("demo", "Demo")', context);
    vm.runInContext(source, context, { filename: 'demo.plugin.js' });
    return context;
}

function install(host, hookSource, kind) {
    const context = runPlugin(`
        var hook = new MethodHook();
        ${hookSource}
        hook_utils.find_class("DemoClass").hook("demoSelector", hook${kind ? ', "' + kind + '"' : ''});
    `, host);
    const record = host.calls.find((entry) => entry[0] === 'installSwizzle');
    assert.ok(record, 'the hook must reach the host');
    return {
        context,
        className: record[1],
        selector: record[2],
        isClassMethod: record[3],
        beforeToken: record[BEFORE_TOKEN],
        afterToken: record[AFTER_TOKEN],
    };
}

test('find_class().hook() installs one hook with both tokens', () => {
    const host = makeHost();
    const hook = install(host, '');
    assert.strictEqual(hook.className, 'DemoClass');
    assert.strictEqual(hook.selector, 'demoSelector');
    assert.strictEqual(hook.isClassMethod, false);
    assert.strictEqual(typeof hook.beforeToken, 'string');
    assert.strictEqual(typeof hook.afterToken, 'string');
});

test('a before hook that sets nothing answers null so the original runs', () => {
    const host = makeHost();
    const hook = install(host, `
        hook.beforeHookedMethod = function (param) {
            globalThis.seenArgs = param.getArgs();
        };
    `);
    const answer = hook.context.__extera.runSwizzleCallback(hook.beforeToken, 'receiver', '["a"]', null);
    assert.strictEqual(answer, null);
    assert.deepStrictEqual(hook.context.seenArgs, ['a']);
});

test('a before hook that calls setResult answers with the replacement as JSON', () => {
    const host = makeHost();
    const hook = install(host, `
        hook.beforeHookedMethod = function (param) {
            param.setResult(["replaced"]);
        };
    `);
    assert.strictEqual(
        hook.context.__extera.runSwizzleCallback(hook.beforeToken, 'receiver', '[]', null),
        '["replaced"]'
    );
});

test('an after hook reads the original result without replacing it', () => {
    const host = makeHost();
    const hook = install(host, `
        hook.afterHookedMethod = function (param) {
            globalThis.readResult = param.getResult();
        };
    `);
    const answer = hook.context.__extera.runSwizzleCallback(hook.afterToken, 'receiver', '[]', '"hello"');
    assert.strictEqual(hook.context.readResult, 'hello', 'afterHookedMethod must see what the method returned');
    assert.strictEqual(answer, null, 'reading the result is not a replacement');
});

test('an after hook replaces the result when it calls setResult', () => {
    const host = makeHost();
    const hook = install(host, `
        hook.afterHookedMethod = function (param) {
            param.setResult(param.getResult() + "!");
        };
    `);
    assert.strictEqual(
        hook.context.__extera.runSwizzleCallback(hook.afterToken, 'receiver', '[]', '"hello"'),
        '"hello!"'
    );
});

test('a hook that throws is logged and does not reach the method', () => {
    const host = makeHost();
    const hook = install(host, `
        hook.beforeHookedMethod = function () { throw new Error("boom"); };
    `);
    assert.strictEqual(hook.context.__extera.runSwizzleCallback(hook.beforeToken, 'receiver', '[]', null), null);
    const logged = host.calls.filter((entry) => entry[0] === 'log').map((entry) => entry[2]);
    assert.strictEqual(logged.length, 1);
    assert.match(logged[0], /hook error/);
});

test('a class-method hook is flagged as one', () => {
    const host = makeHost();
    const hook = install(host, '', 'class');
    assert.strictEqual(hook.isClassMethod, true);
});

test('an unknown class answers null and logs, rather than installing', () => {
    const host = makeHost();
    host.classExists = () => false;
    // `find_class` answers null, exactly as Xposed's `findClass` does for a name
    // that is not loaded — the plugin guards with its own null check.
    const context = runPlugin(`
        globalThis.found = hook_utils.find_class("NopeClass");
    `, host);
    assert.strictEqual(context.found, null);
    assert.strictEqual(host.calls.filter((entry) => entry[0] === 'installSwizzle').length, 0);
    assert.match(host.calls.find((entry) => entry[0] === 'log')[2], /not a loaded Objective-C class/);
});

for (const [name, fn] of tests) {
    try {
        fn();
        console.log('ok ' + name);
    } catch (error) {
        console.log('FAIL ' + name);
        console.log('  ' + error.message);
        process.exitCode = 1;
    }
}