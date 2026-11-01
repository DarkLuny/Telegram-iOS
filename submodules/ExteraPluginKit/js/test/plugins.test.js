/*
 * Checks the seven ported plugins as files on disk.
 *
 * These used to be embedded into the binary as Swift string literals, and this
 * test verified that generator round-tripped them. The plugins are no longer
 * embedded: a plugin is installed by the user from a `.plugin` file, the way
 * exteraGram works. What is still worth checking is that every file in `js/`
 * is a plugin the app can actually install, so this reads them directly.
 *
 * The list is read from the directory rather than hardcoded, so a plugin added
 * without a matching id is caught here instead of showing up as a plugin that
 * installs under the wrong name.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const jsDir = path.join(__dirname, '..', '..', 'js');

const sources = fs.readdirSync(jsDir)
    .filter((name) => name.endsWith('.plugin'))
    .sort()
    .map((name) => path.join(jsDir, name));

if (sources.length === 0) {
    console.log('FAIL: no .plugin files to check');
    process.exit(1);
}

// The same host the runtime exports. A plugin that calls a bridge during load
// reaches one of these; anything missing throws and the check below reports it.
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

let failed = 0;
for (const source of sources) {
    const name = path.basename(source);
    const expectedId = name.replace(/\.plugin$/, '');
    const text = fs.readFileSync(source, 'utf8');

    // A plugin reaches the host under the id its own text declares, so a file
    // that lost or mangled `__id__` would install under the wrong name.
    const idMatch = /__id__\s*=\s*"([^"]+)"/.exec(text);
    if (!idMatch) {
        console.log('FAIL: ' + name + ' has no readable __id__');
        failed += 1;
        continue;
    }
    if (idMatch[1] !== expectedId) {
        console.log('FAIL: ' + name + ' declares id ' + idMatch[1]);
        failed += 1;
        continue;
    }

    // The file has to survive the same evaluation the app performs: a syntax
    // error or a bridge the host does not answer would only show up on device.
    try {
        const context = vm.createContext({ __host: host, console });
        vm.runInContext(bootstrap, context, { filename: 'bootstrap.js' });
        context.__extera.setIdentity(expectedId, name);
        vm.runInContext(text, context, { filename: name });
        vm.runInContext('__extera.finalize()', context);
        if (!context.__extera.instance) {
            throw new Error('no plugin instance after finalize()');
        }
    } catch (error) {
        console.log('FAIL: ' + name + ' does not evaluate: ' + error.message);
        failed += 1;
        continue;
    }

    console.log('ok   ' + name + ' loads (' + text.length + ' chars, id ' + idMatch[1] + ')');
}

// The app ships with no plugins, so the screen has to be able to install each
// one. Every file has to be something the installer would accept: a non-empty
// text file whose extension `PluginFileInstaller.canInstall` recognises.
const accepted = new Set(['.plugin', '.js']);
for (const source of sources) {
    const name = path.basename(source);
    if (!accepted.has(path.extname(name).toLowerCase())) {
        console.log('FAIL: ' + name + ' has an extension the installer rejects');
        failed += 1;
    }
    if (fs.statSync(source).size === 0) {
        console.log('FAIL: ' + name + ' is empty');
        failed += 1;
    }
}
if (failed === 0) {
    console.log('ok   every plugin is a file the installer accepts');
}

console.log(failed === 0 ? '\n' + sources.length + ' plugins checked' : '\n' + failed + ' failed');
process.exit(failed === 0 ? 0 : 1);