/*
 * Checks that generate_bundled_plugins.py turns every js/*.plugin into a Swift
 * literal that reproduces the source exactly, and that each one still parses and
 * carries the id the app will install it under.
 *
 * The list is read from the directory rather than hardcoded, so adding a plugin
 * without adding it to the build is caught here instead of showing up as a
 * plugin that silently does not ship.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

const dir = path.join(__dirname, '..', '..');
const jsDir = path.join(dir, 'js');
const generatorPath = path.join(dir, 'generate_bundled_plugins.py');
const outputPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'plugins-')), 'PluginBundledSources.swift');

const sources = fs.readdirSync(jsDir)
    .filter((name) => name.endsWith('.plugin'))
    .sort()
    .map((name) => path.join(jsDir, name));

if (sources.length === 0) {
    console.log('FAIL: no .plugin files to embed');
    process.exit(1);
}

const python = process.platform === 'win32' ? 'python' : 'python3';
execFileSync(python, [generatorPath, ...sources, '--out=' + outputPath], { stdio: 'inherit' });

const generated = fs.readFileSync(outputPath, 'utf8');
const marker = 'let bundledPluginSources: [String] = [';
const start = generated.indexOf(marker);
if (start < 0) {
    console.log('FAIL: generated file has no plugin array');
    process.exit(1);
}
const arrayText = generated.slice(start + marker.length);

// Splits the array into its string literals. The entries are one per line, and a
// body may contain a `",` sequence, so the split has to honour escapes.
function literalBodies(text) {
    const bodies = [];
    let i = 0;
    while (i < text.length) {
        if (text[i] !== '"') {
            i += 1;
            continue;
        }
        const begin = i;
        i += 1;
        while (i < text.length) {
            if (text[i] === '\\') {
                i += 2;
                continue;
            }
            if (text[i] === '"') {
                break;
            }
            i += 1;
        }
        bodies.push(text.slice(begin, i + 1));
        i += 1;
    }
    return bodies;
}

// The same decoder generated.test.js uses: it accepts only what Swift accepts,
// so a `\u2014` that JSON would allow and Swift would reject fails here.
function decodeSwiftLiteral(text) {
    if (!text.startsWith('"') || !text.endsWith('"') || text.length < 2) {
        throw new Error('literal is not a quoted string');
    }
    const body = text.slice(1, -1);
    let out = '';
    for (let i = 0; i < body.length; i += 1) {
        const character = body[i];
        if (character !== '\\') {
            if (character === '"') throw new Error('bare quote at ' + i);
            out += character;
            continue;
        }
        const next = body[i + 1];
        i += 1;
        switch (next) {
            case '\\': out += '\\'; break;
            case '"': out += '"'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case '0': out += '\0'; break;
            case 'u': {
                if (body[i + 1] !== '{') {
                    throw new Error('unicode escape without braces at ' + i);
                }
                const end = body.indexOf('}', i);
                if (end < 0) throw new Error('unterminated unicode escape at ' + i);
                const hex = body.slice(i + 2, end);
                if (!/^[0-9a-fA-F]{1,8}$/.test(hex)) {
                    throw new Error('bad unicode escape: ' + hex);
                }
                const code = parseInt(hex, 16);
                if (code > 0x10ffff) throw new Error('code point out of range: ' + hex);
                if (code >= 0xd800 && code <= 0xdfff) throw new Error('lone surrogate: ' + hex);
                out += String.fromCodePoint(code);
                i = end;
                break;
            }
            default:
                throw new Error('unsupported Swift escape \\' + next + ' at ' + i);
        }
    }
    return out;
}

const bodies = literalBodies(arrayText);
if (bodies.length !== sources.length) {
    console.log('FAIL: ' + sources.length + ' plugins produced ' + bodies.length + ' literals');
    process.exit(1);
}

// The generator sorts by file name, which is the order the load order follows.
const expectedOrder = sources.map((p) => path.basename(p));
const decoded = bodies.map(decodeSwiftLiteral);
const normalize = (text) => text.replace(/\r\n/g, '\n');

let failed = 0;
for (let index = 0; index < sources.length; index += 1) {
    const name = expectedOrder[index];
    const source = fs.readFileSync(sources[index], 'utf8');
    if (normalize(decoded[index]) !== normalize(source)) {
        console.log('FAIL: ' + name + ' does not round-trip');
        failed += 1;
        continue;
    }
    // A plugin reaches the host under the id its own text declares, so a literal
    // that lost or mangled `__id__` would install under the wrong name.
    const idMatch = /__id__\s*=\s*"([^"]+)"/.exec(decoded[index]);
    if (!idMatch) {
        console.log('FAIL: ' + name + ' has no readable __id__');
        failed += 1;
        continue;
    }
    if (idMatch[1] !== name.replace(/\.plugin$/, '')) {
        console.log('FAIL: ' + name + ' declares id ' + idMatch[1]);
        failed += 1;
        continue;
    }
    console.log('ok   ' + name + ' round-trips (' + decoded[index].length + ' chars, id ' + idMatch[1] + ')');
}

// The literal has to survive the same evaluation the app performs, not only the
// byte comparison: a syntax error would round-trip perfectly and fail on device.
const host = {
    log: () => {},
    getSetting: () => null,
    setSetting: () => true,
    exportSettings: () => ({}),
    importSettings: () => {},
    addHook: () => {},
    addOnSendMessageHook: () => {},
    addMenuItem: () => 'item',
    removeMenuItem: () => {},
    sendText: () => {},
    sendFile: () => {},
    editMessage: () => {},
    showBulletin: () => {},
    showAlert: () => {},
    dismissAlert: () => {},
    fileOp: () => 'null',
    selectedAccount: () => 0,
    appVersion: () => '13.1.1',
    pluginDirectory: () => '/plugins/x',
    schedulePlugin: () => {},
    openUrl: () => true,
    themeColors: () => '{}',
    httpGet: () => {},
    proxyList: () => {},
    proxyAdd: () => {},
    proxyRemoveAll: () => {},
    ownPeerId: () => {},
};
const bootstrap = fs.readFileSync(path.join(jsDir, 'bootstrap.js'), 'utf8');
for (let index = 0; index < decoded.length; index += 1) {
    const name = expectedOrder[index];
    try {
        const context = vm.createContext({ __host: host, console });
        vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
        context.__extera.setIdentity(name.replace(/\.plugin$/, ''), name);
        vm.runInContext(decoded[index], context, { filename: name });
        vm.runInContext('__extera.finalize()', context);
        if (!context.__extera.instance) {
            throw new Error('no plugin instance after finalize()');
        }
    } catch (error) {
        console.log('FAIL: ' + name + ' does not evaluate: ' + error.message);
        failed += 1;
    }
}
if (failed === 0) {
    console.log('ok   every embedded plugin evaluates');
}

console.log(failed === 0 ? '\n' + sources.length + ' plugins embedded' : '\n' + failed + ' failed');
process.exit(failed === 0 ? 0 : 1);