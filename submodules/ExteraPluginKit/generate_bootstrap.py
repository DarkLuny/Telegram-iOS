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


TEMPLATE = """// Generated from {source} by generate_bootstrap.py. Do not edit.
let pluginBootstrapJavaScript: String = {literal}
"""

# Characters Swift spells differently from JSON, or that a Swift string literal
# cannot carry raw.
SIMPLE_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\0": "\\0",
}


def swift_literal(body: str) -> str:
    """Escape `body` into a Swift string literal.

    `json.dumps` is *not* enough. It writes Unicode as `\\u2014`, which Swift
    rejects ("expected hexadecimal code in braces after unicode escape") because
    its form is `\\u{2014}`. That only shows up at compile time, once a
    non-ASCII character reaches bootstrap.js — an em dash in a comment took a
    full build to find.

    Everything else that could break the literal is escaped too: a raw newline
    or tab, a quote, and any other control character. Backslashes are escaped
    first, so nothing in the source can leave a bare `\\(` behind, which is how
    Swift starts an interpolation.
    """
    parts = []
    for character in body:
        escape = SIMPLE_ESCAPES.get(character)
        if escape is not None:
            parts.append(escape)
        elif character < " " or character == "\x7f":
            parts.append("\\u{%x}" % ord(character))
        elif ord(character) > 126:
            # `\\u{...}` takes a whole code point, so an emoji needs no surrogate
            # pair; `ord()` already gives the scalar value Python iterated to.
            parts.append("\\u{%x}" % ord(character))
        else:
            parts.append(character)
    return '"' + "".join(parts) + '"'


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    with open(arguments.source, encoding="utf-8") as handle:
        body = handle.read()

    literal = swift_literal(body)

    with open(arguments.out, "w", encoding="utf-8") as handle:
        handle.write(TEMPLATE.format(source=arguments.source, literal=literal))


if __name__ == "__main__":
    main()
