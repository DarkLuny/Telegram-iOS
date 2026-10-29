/*
 * Checks that the generated Swift literal reproduces js/bootstrap.js exactly.
 * A silent escaping bug here would ship a plugin runtime that differs from the
 * one the tests cover, so this is verified rather than assumed.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = path.join(__dirname, '..', '..');
const generatedPath = path.join(dir, 'PluginBootstrap.generated.swift');
const sourcePath = path.join(dir, 'js', 'bootstrap.js');

if (!fs.existsSync(generatedPath)) {
    console.log('skip: PluginBootstrap.generated.swift not generated yet');
    process.exit(0);
}

const generated = fs.readFileSync(generatedPath, 'utf8');
const marker = 'let pluginBootstrapJavaScript: String = ';
const start = generated.indexOf(marker);
if (start < 0) {
    console.log('FAIL: generated file has no literal');
    process.exit(1);
}
const literal = generated.slice(start + marker.length).replace(/\s+$/, '');
const decoded = JSON.parse(literal);
const original = fs.readFileSync(sourcePath, 'utf8');

if (decoded !== original) {
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