/*
 * Checks that generate_bootstrap.py turns js/bootstrap.js into a Swift literal
 * that reproduces the script exactly.
 *
 * The literal is not committed: a checked-in copy would be a second source that
 * can drift from js/bootstrap.js, which is precisely what embedding the script
 * instead of shipping it as a resource is meant to avoid. The generator is run
 * here instead, into a temporary file.
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
const decoded = JSON.parse(literal);
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
