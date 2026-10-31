#!/usr/bin/env python3
"""Turns the ported `js/*.plugin` files into Swift string literals.

The plugins ship with the app so that installing the IPA is enough to get them:
on iOS the app's Documents folder is not reachable without the document picker
(`UIFileSharingEnabled` is off), so a user cannot simply drop a file into
`Plugins/` the way an Android user drops one into the plugin folder.

The plugin sources are written as JavaScript and tested with `node`, so shipping
them as a resource would mean the binary could carry a different copy from the
one the tests exercise. Embedding them as literals keeps one source of truth, the
same way `generate_bootstrap.py` does for the bootstrap.

Each file is listed individually rather than as a directory, because Bazel stages
declared inputs flat: the directory the sources live in during a build is not the
one they live in in the repository.

The declared id is *not* carried here: `PluginLoader.readManifest` reads it from
the source text, and that is the id the plugin installs under. A file name that
disagrees with `__id__` therefore cannot install a plugin twice.

Usage:
    python3 generate_bundled_plugins.py js/a.plugin js/b.plugin --out=...
"""

import argparse

from generate_bootstrap import swift_literal


TEMPLATE = """// Generated from {names} by generate_bundled_plugins.py. Do not edit.
//
// The plugins that ship with the app, sorted by file name so the load order is
// stable. `PluginManager` installs each one on first launch and never touches a
// copy the user already has, so a plugin the user removed stays removed and one
// they updated stays updated.
let bundledPluginSources: [String] = [
{entries}
]
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", help="the .plugin files to embed")
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    paths = sorted(arguments.sources, key=lambda path: path.replace("\\", "/").rsplit("/", 1)[-1])
    entries = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        entries.append("    " + swift_literal(body) + ",")

    if not entries:
        raise SystemExit("no .plugin files given")

    with open(arguments.out, "w", encoding="utf-8") as handle:
        handle.write(TEMPLATE.format(
            names=", ".join(path.replace("\\", "/").rsplit("/", 1)[-1] for path in paths),
            entries="\n".join(entries),
        ))


if __name__ == "__main__":
    main()