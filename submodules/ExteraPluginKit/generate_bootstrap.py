#!/usr/bin/env python3
"""Turns js/bootstrap.js into a Swift string literal.

The plugin bootstrap is written as JavaScript so `node js/test` can exercise the
exact code the app runs. Shipping it as a resource would mean the binary could
drift from that file; embedding it as a literal keeps one source. Escaping it by
hand into Swift would create a second copy to keep in sync, which is the bug this
script exists to avoid.

Usage:
    python3 generate_bootstrap.py --source=js/bootstrap.js --out=PluginBootstrap.swift
"""

import argparse
import json


TEMPLATE = """// Generated from {source} by generate_bootstrap.py. Do not edit.
let pluginBootstrapJavaScript: String = {literal}
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    with open(arguments.source, encoding="utf-8") as handle:
        body = handle.read()

    # JSON string escaping is a valid Swift string literal body for this file:
    # it has no literal tabs and no characters above the BMP.
    literal = json.dumps(body)

    with open(arguments.out, "w", encoding="utf-8") as handle:
        handle.write(TEMPLATE.format(source=arguments.source, literal=literal))


if __name__ == "__main__":
    main()