load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# bootstrap.js is the plugin-visible API (BasePlugin, HookResult, ui.settings,
# ...). It is written as JavaScript so it can be unit-tested with node, and
# converted to a Swift string literal at build time so the binary carries it as
# a resource-free constant. Hand-escaping it into Swift would be a second copy
# to keep in sync, which is exactly the bug this avoids.
genrule(
    name = "PluginBootstrapSource",
    srcs = ["js/bootstrap.js"],
    outs = ["PluginBootstrap.swift"],
    cmd = """
        python3 - "$$(location js/bootstrap.js)" "$@" <<'PY'
import json, sys
source, destination = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    body = handle.read()
# JSON string escaping is a valid Swift string literal body for everything this
# file contains (no literal tabs, no unicode above the BMP).
with open(destination, "w", encoding="utf-8") as handle:
    handle.write("// Generated from js/bootstrap.js by the PluginBootstrapSource genrule.\\n")
    handle.write("let pluginBootstrapJavaScript: String = " + json.dumps(body) + "\\n")
PY
    """,
    visibility = ["//visibility:public"],
)

swift_library(
    name = "ExteraPluginKit",
    module_name = "ExteraPluginKit",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [":PluginBootstrap.swift"],
    copts = [
        "-warnings-as-errors",
    ],
    # JavaScriptCore is part of the OS; no bundled engine, no added IPA size.
    sdk_frameworks = [
        "JavaScriptCore",
        "UniformTypeIdentifiers",
    ],
    deps = [
        # `PluginRuntime` is the only file that needs the app's account/transport
        # side; `PluginManager`/`PluginStore`/`PluginLoader` stay Foundation plus
        # JavaScriptCore. TelegramUI is deliberately absent: it depends on this
        # module, so importing it here would be a cycle.
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TextFormat:TextFormat",
    ],
    visibility = [
        "//visibility:public",
    ],
)