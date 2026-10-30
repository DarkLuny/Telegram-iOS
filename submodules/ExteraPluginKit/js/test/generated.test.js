/*
 * Checks that generate_bootstrap.py turns js/bootstrap.js into a Swift literal
 * that reproduces the script exactly.
 *
 * The literal is not committed: a checked-in copy would be a second source that
 * can drift from js/bootstrap.js, which is precisely what embedding the script
 * instead of shipping it as a resource is meant to avoid. The generator is run
 * here instead, into a temporary file.
 *
 * The output is *Swift*, not JSON, and the difference is not cosmetic: Swift
 * spells a non-ASCII escape `\u{2014}` while JSON uses `\u2014`, and evaluating
 * the literal with `JSON.parse` cannot tell the two apart. A single em dash in a
 * comment therefore decoded fine here and failed the real build with
 * "expected hexadecimal code in braces after unicode escape". The decoder below
 * accepts only what Swift accepts, so that class of bug fails in a second.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

const dir = path.join(__dirname, '..', '..');
const sourcePath = path.join(dir, 'js', 'bootstrap.js');
const generatorPath = path.join(dir, 'generate_bootstrap.py');
const outputPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bootstrap-')), 'PluginBootstrap.swift');

// `python3` is the CI name; a Windows checkout usually only has `python`.
const python = process.platform === 'win32' ? 'python' : 'python3';
execFileSync(python, [generatorPath, '--source=' + sourcePath, '--out=' + outputPath], { stdio: 'inherit' });

const generated = fs.readFileSync(outputPath, 'utf8');
const marker = 'let pluginBootstrapJavaScript: String = ';
const start = generated.indexOf(marker);
if (start < 0) {
    console.log('FAIL: generated file has no literal');
    process.exit(1);
}
const literal = generated.slice(start + marker.length).replace(/\s+$/, '');

// Decodes a Swift string literal body, refusing anything Swift would refuse.
function decodeSwiftLiteral(text) {
    if (!text.startsWith('"') || !text.endsWith('"') || text.length < 2) {
        throw new Error('literal is not a quoted string: ' + JSON.stringify(text.slice(0, 40)));
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
                // Swift also has \( ) interpolation and \x; none may appear.
                throw new Error('unsupported Swift escape \\' + next + ' at ' + i);
        }
    }
    return out;
}

const decoded = decodeSwiftLiteral(literal);
// Compare with normalized newlines: `core.autocrlf` turns the source into CRLF
// on a Windows checkout while the generator writes LF, and both describe the
// same script.
const normalize = (text) => text.replace(/\r\n/g, '\n');
if (normalize(decoded) !== normalize(fs.readFileSync(sourcePath, 'utf8'))) {
    console.log('FAIL: generated literal does not match js/bootstrap.js');
    process.exit(1);
}
console.log('ok   generated literal round-trips (' + decoded.length + ' chars)');

const context = vm.createContext({ __host: { log: () => {}, showBulletin: () => {} }, console });
vm.runInContext(decoded, context);
if (!context.__extera || !context.__extera.api) {
    console.log('FAIL: decoded script does not evaluate');
    process.exit(1);
}
console.log('ok   decoded script evaluates');