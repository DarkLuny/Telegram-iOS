# exteraGram plugin API — iOS runtime

Version of this runtime's API surface: **1.4.5.0** (the value `__sdk_version__` is
compared against). Shape and names follow the exteraGram plugin SDK
(`plugins.exteragram.com/docs`, SDK `1.4.4.3`); the runtime here is JavaScriptCore,
not Python 3.11 + Chaquopy.

Baseline app: **13.1.1**. A plugin declares its own minimum with
`__app_version__`.

---

## Contents

1. [Plugin file](#1-plugin-file)
2. [Metadata](#metadata)
3. [Lifecycle](#2-lifecycle)
4. [Hooks](#3-hooks)
5. [HookResult, HookStrategy](#4-hookresult-hookstrategy)
6. [Menu items](#5-menu-items)
7. [Settings: ui.settings](#6-settings-uisettings)
8. [Settings storage](#7-settings-storage)
9. [Sending: client_utils](#8-sending-clientutils)
10. [Multi-account](#9-multi-account)
11. [Schedulers and threads](#10-schedulers-and-threads)
12. [HTTP](#11-http)
13. [Proxy](#12-proxy)
14. [Text formatting](#13-text-formatting)
15. [Bulletins and dialogs](#14-bulletins-and-dialogs)
16. [Files: file_utils](#15-files-fileutils)
17. [Appearance hooks](#16-appearance-hooks)
18. [Saved deleted messages](#17-saved-deleted-messages)
19. [Logging](#18-logging)
20. [Android-only surfaces](#19-android-only-surfaces)
21. [Controller proxies](#20-controller-proxies)
22. [Intents](#21-intents)
23. [Porting checklist](#22-porting-checklist)
24. [JS ↔ Swift bridge (host internals)](#23-js--swift-bridge-host-internals)

---

## 1. Plugin file

A plugin is one UTF-8 text file, at most 4 MB, opened from a chat in the client
and installed there. The file must contain:

1. **Metadata as plain top-level constants** — the loader reads them from the
   text before evaluating, so they must be literal assignments, never computed.
2. **One class extending `BasePlugin`**, named `Plugin` (or passed to
   `__extera.register`).

```js
var __id__ = "hello_world";
var __name__ = "Hello World";
var __description__ = "My first plugin";
var __author__ = "@yourUsername";
var __version__ = "1.0.0";

class HelloWorldPlugin extends BasePlugin {
    on_plugin_load() {
        this.log("loaded");
    }
}

var Plugin = HelloWorldPlugin;
```

The runtime instantiates `Plugin` itself after the file has been evaluated, then
calls `on_plugin_load`. If a plugin builds its instance some other way it must
hand it over with `__extera.register(instance)`.

A file whose body is Python (imports, `def`, a Python class body) is refused with
a message saying so, rather than half-loaded.

### Elyx containers

A `.elyx` archive — the format the SDK's builder produces for a multi-file
project — is accepted too. It is a ZIP whose entry is a YAML `metainfo` plus an
`assets` tree and one or more JavaScript modules. The plugin's entry module is
`main` from `metainfo` (or `main.elyx.js`), and the modules it `require`s are
resolved inside the archive, with a CommonJS cache and cycle guard.

```yaml
# metainfo
id: my_plugin
name: My Plugin
version: 1.0.0
main: src/index.js
```

Inside an Elyx plugin, `elyx` exposes the archive's own parts: `elyx.assets`
(the asset collection, with `content`/`content_bytes`/`content_string`/
`content_json`), `elyx.strings` (the localised catalogues, with `pluralize`),
`elyx.metainfo`, `elyx.refmap`, `elyx.settings`, `elyx.get_environment()`,
`elyx.import_module(name)` and `elyx.Asset.from_path`. `elyx.temp_asset_from_url`
is **asynchronous** here (the Android SDK's is synchronous): it takes a callback
and calls it with the ready asset.

The Python parts of the Elyx stack — `import_module` in Python semantics, wheels
with a Python ABI, `mvel_execute`, the `gen`/`gen2` Java proxies — have no iOS
counterpart and are stubs that throw with a reason rather than vanish.

### Metadata

| Constant | Required | Notes |
|---|---|---|
| `__id__` | yes | 2–32 chars: letters, digits, `_`, `-`. Identifies the plugin everywhere: storage, log, bridge calls. |
| `__name__` | yes | Shown in the plugin list. |
| `__description__` | no | Shown on the plugin's page. |
| `__author__` | no | Free text. |
| `__version__` | no | Default `"1.0"`. |
| `__icon__` | no | `StickerPackShortName/index`; resolved by the client when it can, otherwise the row shows initials. |
| `__app_version__` | no | `>=13.1.1`, `<=1.2`, `==1.0`, `>1`, `<2`. A bare value means `>=`. |
| `__min_version__` | no | Legacy alias of `__app_version__`. |
| `__sdk_version__` | no | Gate on this runtime's API level. Current value is `1.4.5.0`. |
| `__requirements__` | no | Refused: this runtime cannot install Python packages. A plugin declaring any fails to load with a message naming them. |

Version comparison pads with zeros, so `12.5` and `12.5.0` are equal.

---

## 2. Lifecycle

```js
class P extends BasePlugin {
    on_plugin_load() {          // enable, and on app startup with the plugin enabled
    }
    on_plugin_unload() {        // disable, and on app shutdown
    }
    on_app_event(event) {       // AppEvent value
    }
}
```

`AppEvent` values: `START`, `STOP`, `PAUSE`, `RESUME` (`'start'`, `'stop'`,
`'pause'`, `'resume'`). `START` is delivered after the load, so
`on_plugin_load` has already run.

Everything a plugin starts outside the client — a timer, an observer, a long
request — must be stopped in `on_plugin_unload`.

---

## 3. Hooks

Registered inside `on_plugin_load`. A method that exists but was never registered
is never called, which is the same trap as in the SDK.

```js
on_plugin_load() {
    this.add_hook("messages.setTyping");     // dotted TL name
    this.add_hook("TL_account_updateStatus");// TL_ spelling also matches
    this.add_hook("messages.", true);        // match_substring: whole namespace
    this.add_on_send_message_hook();         // outgoing messages
}
```

| Hook method | Signature | Can change |
|---|---|---|
| `pre_request_hook` | `(name, account, request)` | `request` |
| `post_request_hook` | `(name, account, response, error)` | nothing (observational) |
| `on_update_hook` | `(name, account, update)` | nothing (observational) |
| `on_updates_hook` | `(name, account, updates)` | nothing (observational) |
| `on_send_message_hook` | `(account, params)` | `params` |

`name` is both spellings in one: the callback receives the `TL_` form
(`TL_messages_setTyping`, `TL_updateNewMessage`), and a registration in either
spelling matches the other.

`params` for the send hook is `{message, peer, account}`. Returning
`HookResult.cancel()` drops the send; replacing `params.message` and returning
`HookResult.modify("params", params)` rewrites the text.

`post_request_hook` and the update hooks are **detached**: they run on the script
queue after the event, and nothing they return reaches the client. A slow plugin
cannot stall the account state through them, and it cannot rewrite an update
either.

`pre_request_hook` is called synchronously, on the network thread, through the
script queue. It must be quick.

Requests and updates cross the bridge as objects of fields; a nested TL value is
an object with `_` (the constructor name) and its own fields, to depth 8. So
`update.message.peer_id` and `update.message.id` read the way they do on Android.

### Xposed-style hooks (Objective-C swizzling)

The client's own hooks above cover TL traffic. To reach an app method directly —
the Xposed case — use `hook_utils.find_class` and `.hook`, which swizzle an
Objective-C method at runtime:

```js
var cls = hook_utils.find_class("SpeakerNode");   // a loaded ObjC class, or null
var token = cls.hook("setMessage:", new MethodHook() { /* see below */ });
```

In practice a plugin constructs a `MethodHook` with the two callbacks:

```js
var hook = new MethodHook();
hook.beforeHookedMethod = function (param) {
    var args = param.getArgs();          // the receiver and up to two object args
    // param.setResult(x) replaces the method's return and skips the original.
};
hook.afterHookedMethod = function (param) {
    // Observes after the original ran; may also setResult.
};
hook.setPriority(50);                    // order among hooks on one method
hook_utils.find_class("SomeClass").hook("someSelector:", hook);
```

`param` carries the SDK's own methods: `getArgs`, `getArg(index)`, `setResult`,
`getResult`, `getObjectExtra(key)`, `setObjectExtra(key, value)`.

What can be hooked: an Objective-C method that already exists on a class the app
has loaded, taking zero, one or two object arguments, returning an object or
nothing. What cannot: a Swift method not exposed with `@objc` (there is no such
selector to find), a C function, a method taking a struct or a primitive, and
anything that would have to exist before the plugin runs. A class or selector
that resolves to nothing is reported in the log, never created.

A signature outside that set is refused with a reason rather than installed —
`hook("foo:")` on a method that takes a `CGFloat` answers null and logs the type
encoding. Swizzling it with a block that returns an object would not crash
immediately; it would corrupt the return value of every call, which is a much
worse bug to find later. The block is dispatched at the arity the method
actually has, so a zero-argument method is not handed two uninitialised
registers.

The callbacks run in Xposed's order, and the original is always called unless a
hook replaced the result:

- `beforeHookedMethod(param)` — runs first. `param.setResult(x)` skips the
  original and becomes the method's return value. Returning nothing lets the
  original run.
- the original implementation.
- `afterHookedMethod(param)` — runs with `param.getResult()` set to what the
  original returned. Reading it changes nothing; `setResult` there replaces it.

`setResult` values cross the bridge as JSON, so an array arrives as an array and
`null` arrives as `nil`, not as the strings `"[]"` and `"null"`.

Hooks are installed once per class+selector (a second install is a no-op) and are
all restored when plugins unload, so a removed plugin's block cannot keep running.

`hook_utils.get_private_field` / `set_private_field` have no equivalent — a Swift
property with no `@objc` cannot be reached by name — and log rather than guess.

---

## 4. HookResult, HookStrategy

```js
HookResult()                               // nothing asked for
HookResult({strategy: HookStrategy.MODIFY, request: request})
HookResult.cancel()
HookResult.modify("params", params)
```

| Strategy | Effect |
|---|---|
| `HookStrategy.DEFAULT` | do nothing special |
| `HookStrategy.CANCEL` | stop the operation (pre-request, send) |
| `HookStrategy.MODIFY` | use the returned object; later plugins see it |
| `HookStrategy.MODIFY_FINAL` | modify and stop the chain |

The field carrying the replacement depends on the hook: `request`, `response`,
`update`, `updates`, `params`. Hooks run in plugin load order on the send and
pre-request paths, and the first `cancel` stops the chain.

---

## 5. Menu items

```js
on_plugin_load() {
    this._item = this.add_menu_item(MenuItemData({
        menu_type: MenuItemType.MESSAGE_CONTEXT_MENU,
        text: "Message info",
        icon: "msg_info",
        subtext: "Debug",
        priority: 10,
        on_click: (ctx) => this.log("id=" + ctx.message.id),
    }));
}

on_plugin_unload() {
    if (this._item) { this.remove_menu_item(this._item); }
}
```

`menu_type`: `MESSAGE_CONTEXT_MENU`, `DRAWER_MENU`, `MAIN_MENU`,
`CHAT_ACTION_MENU`, `PROFILE_ACTION_MENU`.

`MenuItemData` fields: `menu_type`, `text`, `on_click`, `item_id`, `icon`,
`subtext`, `condition`, `priority`. `add_menu_item` returns the item id (a
stable `item_id` if one was given, otherwise a generated one).

`condition` may be a function or a string expression. A string is compiled once
per context shape and sees every context key as a variable, so `dialog_id > 0`
reads the way the MVEL version does in exteraGram. A condition that throws or
cannot be compiled hides the item.

`on_click` receives the context object: `account`, `peer_id`, `dialog_id`, and
whatever else describes the place the menu was opened from. Log
`Object.keys(ctx)` to see what a given menu offers.

Existing items are removed automatically on unload; `remove_menu_item` is for
doing it earlier.

---

## 6. Settings: ui.settings

Implement `create_settings()` and return a list of controls.

```js
create_settings() {
    return [
        Header({text: "General"}),
        Switch({key: "enabled", text: "Enable feature", default: true,
                subtext: "Sample switch", icon: "msg_settings",
                on_change: (value) => this.log("switch: " + value)}),
        Selector({key: "mode", text: "Mode", default: 1,
                  items: ["Off", "Basic", "Advanced"]}),
        Input({key: "name", text: "Name", default: "Alice"}),
        EditText({key: "token", hint: "Token", multiline: false}),
        Divider({text: "Section"}),
        Text({text: "Sub-page", icon: "msg_arrow_forward",
              create_sub_fragment: () => this._sub_page()}),
        Text({text: "Warning", red: true}),
        Custom({text: "Custom row", on_click: (row) => this.log(row.key)}),
    ];
}

_sub_page() {
    return [Header({text: "Sub-page"}), Text({text: "Nested settings."})];
}
```

| Control | `type` | Key fields |
|---|---|---|
| `Header({text})` | `header` | section title |
| `Divider({text})` | `divider` | optional caption |
| `Switch({key, text, default, subtext, icon, on_change, on_long_click, link_alias})` | `switch` | `default` is a bool |
| `Selector({key, text, default, items, icon, on_change, on_long_click, link_alias})` | `selector` | `default` is an index into `items` |
| `Input({key, text, default, subtext, icon, on_change, on_long_click, link_alias})` | `input` | single-line text |
| `EditText({key, hint, default, multiline, max_length, mask, on_change, link_alias})` | `edit_text` | `hint` is the placeholder |
| `Text({text, subtext, icon, accent, red, on_click, on_long_click, create_sub_fragment, link_alias, key})` | `text` | tappable row; `red`/`accent` colour it |
| `Custom({item, view, factory, factory_args, on_click, on_long_click, create_sub_fragment, link_alias, text, subtext})` | `custom` | see below |

Notes:

- Controls are plain objects; `new Switch({...})` and `Switch({...})` both work.
- A control with a `key` persists under it. Without one, the key is derived from
  `text`/`hint` plus the row's index, which is stable across launches because
  the text is. `Text` accepts an explicit `key` too, for text that is
  translated.
- A stored switch reaches `get_setting` and `on_change` as a real boolean, not
  `1`. `plugin.get_setting("x", false) === true` is a valid test.
- `on_change(value)` gets the new value. `on_click(row)` and `on_long_click(row)`
  get `{key, getKey()}` — there is no Android `View` here, so the row's key
  stands in for it. A plugin that only logs or runs its own logic is unaffected.
- `create_sub_fragment()` returning another list opens a nested page.
- `link_alias` on a `Text`/`Custom` row with no `on_click` opens the screen the
  alias names: `plugins` is the one alias that resolves (it opens the plugin
  list). Any other alias is logged, because iOS has no settings-key deeplinks to
  route it to. A row with its own `on_click` keeps it; `link_alias` is the
  fallback, as in the SDK.
- The Android-only fields of `Custom` (`item`, `view`, `factory`,
  `factory_args`) are accepted and ignored; the renderer draws a row from
  `text`/`subtext` and calls `on_click`. `SimpleSettingFactory` exists so a
  ported settings list keeps its shape:

```js
var PreviewFactory = ui.settings.SimpleSettingFactory(createView, bindView, {
    is_clickable: true,
    on_click: function (plugin, item, view) { plugin.log("clicked"); },
    text: "Sticker pack",
    subtext: "exteraPlugins/1",
});

var row = PreviewFactory({"link_alias": "sticker_preview"});
var row2 = PreviewFactory("CactusPlugins", 0);   // positional args land in factory_args
// PreviewFactory.instance.java is the doc's spelling of the same object.
```

---

## 7. Settings storage

```js
this.get_setting(key, fallback)      // fallback used when the key was never saved
this.set_setting(key, value, reload) // reload=true rebuilds an open settings screen
this.export_settings()               // {key: value, ...}
this.import_settings(values, reload)
```

`reload` is for the case where the *structure* of the screen depends on the
value; a plain value change reaches the row on its own.

Companions on the plugin instance:

```js
this.getId();                  // the plugin id
this.getName();                // the plugin name
this.log(text);                // write to the plugin log
this.get_plugin_directory();   // the plugin's own folder, same as file_utils.get_plugins_dir()
this.show_bulletin("info", "text");   // one-line bulletin without ui.bulletin
this.get_hook_account();       // the account the running callback fired for, else null
this.run_on_ui_thread(fn);     // same as this.run_on_queue(fn, 0)
```

---

## 8. Sending: client_utils

Every helper accepts a trailing options object; `account` in it selects the
account, otherwise the hook's account or the selected one is used.

```js
this.send_text(peerId, "Hello from my plugin");
this.send_text(peerId, "**Hello** from my *plugin*!", {parse_mode: "Markdown"});
this.send_text(peerId, "This is a reply.", {replyToMsg: 9876});

this.send_photo(peerId, "/path/image.jpg", {caption: "Here.", high_quality: true});
this.send_document(peerId, "/path/file.zip", {caption: "Here is the zip."});
this.send_video(peerId, "/path/video.mp4", {caption: "Check this out!"});
this.send_audio(peerId, "/path/song.mp3", {caption: "Listen!"});

this.send_message({peer: peerId, message: "Scheduled", scheduleDate: 1735689600, notify: false});
this.send_message({peer: peerId, caption: "<b>Bold</b>", photo: "/path/p.jpg", parse_mode: "HTML"});
this.send_message({peer: peerId, message: "Header", entities: [new TLRPC.TL_messageEntityBold()]});

this.edit_message({peer: peerId, id: messageId}, "New text.");
this.edit_message({peer: peerId, id: messageId}, "New photo.", {file_path: "/path/another.jpg"});
```

`parse_mode` is case-insensitive and accepts `HTML` and `Markdown`. When it is
given, the formatting markers are stripped into entities on the JS side by the
same parser `parse_text` uses; without it the text goes through as typed and the
client detects bare links and mentions itself.

For media, `parse_mode` applies to `caption`. `high_quality` is read from
`high_quality`/`sendingHighQuality`.

Common options: `account`, `replyToMsg`, `notify`, `scheduleDate`, `caption`,
`parse_mode`, `file_path`, `with_spoiler`, `hasMediaSpoilers`, `ttl`.

The module-level forms are the same functions:

```js
client_utils.send_text(peerId, "hi", {account: account});
client_utils.get_client(account).send_text(peerId, "hi");
client_utils.parse_text("<b>x</b>", "HTML");
client_utils.get_client_version();       // "13.1.1", or "Unknown"
client_utils.get_hook_account();         // account of the running callback, else null
client_utils.get_selected_account();
```

`get_client(account)` returns an `AccountClient`: `send_text`, `send_photo`,
`send_document`, `send_video`, `send_audio`, `send_message`, `edit_message`, plus
`get_account()`.

### Two names that are not global

Two names the SDK puts at the top level are reachable here only through their
module object. This is not "fixed" in the document, because it is what the build
actually does and a plugin written against the SDK will hit it:

- `parse_text` — **not** a global. Use `client_utils.parse_text(...)` or
  `extera_utils.text_formatting.parse_text(...)`. The SDK's `var p = parse_text(...)`
  line throws `ReferenceError` here.
- `SimpleSettingFactory` — **not** a global. Use
  `ui.settings.SimpleSettingFactory(...)` (the same object as
  `__extera.api.SimpleSettingFactory`).

`BasePlugin` and the settings controls are real globals, so a port works on them
without edits.

---

## 9. Multi-account

Every logged-in account keeps its connection and keeps firing hooks. Every hook
callback receives `account`; anything the callback does must use it.

```js
on_update_hook(name, account, update) {
    var client = this.client(account);       // follows the hook scope
    client.send_text(update.message.peer_id, "reply");
    return new HookResult();
}
```

- `this.client(account)` / `this.client()` / `get_client(account)` — account-bound helpers.
- `this.get_hook_account()` / `get_hook_account()` — the account the running callback fired for, `null` outside a callback.
- `get_selected_account()` — the account visible in the UI, when that is genuinely what is wanted.
- Work scheduled with `run_on_queue` from inside a callback keeps that callback's account scope.

---

## 10. Schedulers and threads

```js
this.run_on_queue(fn);                    // serialized on the script queue
this.run_on_queue(fn, 2500);              // after 2500 ms
this.run_on_queue(fn, GLOBAL_QUEUE, 2500);// queue name accepted and ignored
this.run_on_ui_thread(fn);                // main-queue work (dialogs, bulletins)
android_utils.run_on_ui_thread(fn, 500);
```

Queue constants exist for shape and are accepted, then ignored — there is one
script queue: `STAGE_QUEUE`, `GLOBAL_QUEUE`, `CACHE_CLEAR_QUEUE`, `SEARCH_QUEUE`,
`PHONE_BOOK_QUEUE`, `THEME_QUEUE`, `EXTERNAL_NETWORK_QUEUE`, `PLUGINS_QUEUE`.

Anything slow — network, file I/O, parsing — goes through `run_on_queue`. The
script queue is shared by every plugin, so blocking it blocks all of them.

---

## 11. HTTP

Requests are answered through a callback. Never blocking.

```js
http.get("https://example.com/list.txt", {headers: {"Accept": "text/plain"}, timeout: 10}, function (r) {
    if (!r.ok) { this.log("failed: " + r.error); return; }
    this.log(r.status + " " + r.text);
});

http.get_json("https://example.com/actual.json", function (r) {
    if (r.ok && r.json) { this.log("version " + r.json.version); }
});
```

Answer shape: `{ok, status, text, error, json?}`. A transport failure or a
non-2xx status is `ok: false`, with `status` and `text` still present when there
is a body, because a 404 body often explains the failure. `get_json` parses
`text` and puts the result in `json`; an unparseable body is `ok: false` with the
text kept.

### Verbs beyond GET

`post`, `put`, `patch`, `delete` and a general `request` are implemented, each
taking an options object with `headers`, a `body` (string or a value that is
JSON-stringified), `timeout`, and the same callback:

```js
http.post("https://example.com/items", {body: {name: "x"}, headers: {"Content-Type": "application/json"}}, cb);
http.put("https://example.com/items/1", {body: JSON.stringify({name: "y"})}, cb);
http.patch(url, {body: "..."}, cb);
http.delete(url, {headers: {...}}, cb);

// The general form, for a method not listed above.
http.request("OPTIONS", url, {headers: {...}, body: "..."}, cb);
```

The `*_json` variants (`post_json`, `put_json`, `patch_json`) parse the response
body into `r.json`, the same as `get_json`. A request body that is not UTF-8
safe is carried as base64 across the bridge; `http` encodes and decodes it on the
JavaScript side, because `btoa` is absent in JavaScriptCore.

Also aliased as `client_utils.http_get`, `client_utils.http_post`,
`client_utils.http_put`, `client_utils.http_patch`, `client_utils.http_delete`,
`client_utils.http_request`, and the `*_json` forms.

---

## 12. Proxy

Reading and editing the client's proxy list.

```js
proxy.list(function (r) {
    // r = {ok, servers: [{link, kind, host, port}, ...]}  kind: mtproto|web|socks
});

proxy.add(["tg://proxy?server=1.2.3.4&port=443&secret=dd..."], function (r) {
    // r = {ok, added, skipped}
});

proxy.remove_all(function (r) { /* r = {ok, removed} */ });

proxy.own_peer_id(function (r) { /* r = {ok, peer_id} */ });
proxy.own_peer_id(account, function (r) { });

var parsed = proxy.parse_link("tg://proxy?server=1.2.3.4&port=443&secret=ee...");
// {kind: "mtproto", host, port, secret, subtype: "faketls"|"padding", link}
var key = proxy.protocol_key(parsed);   // "mtproto_faketls" | "web_websocket" | "socks" | ...
```

`add` takes links, not objects. `list` reports the whole list, not the active
server. `parse_link` is pure JS and answers `null` for anything it cannot read.

Also aliased as `client_utils.proxy_list` / `client_utils.get_own_peer_id`.

### 12.1 Local MTProxy

A plugin cannot open a socket: iOS gives the JavaScript context no sockets and
no way to listen on a port. The client owns that listener instead, which is the
one capability a plugin cannot build for itself.

`proxy.local_start(domain)` runs an MTProxy on `127.0.0.1` (port 1443 when free,
otherwise an ephemeral port) with a fresh `dd` secret, **adds its
`tg://proxy?server=127.0.0.1&port=…&secret=dd…` entry to the proxy list and
makes that entry active**, so the client's own traffic uses it at once and the
entry is visible in Settings → Privacy → Proxy exactly as a hand-added one is.

`domain` is a CloudFlare zone whose `kws<dc>.<domain>` names answer (the
`tg-ws-proxy` arrangement). The tunnel dials `kws<dc>.<domain>` over WSS, falls
back to `kws<dc>.web.telegram.org` and then to the datacenter address, so a zone
that stops answering does not take the transport down.

```js
proxy.local_start("pclead.co.uk", function (r) {
    // r = {ok, status: {running, host, port, domain, active, connections,
    //                   upstreams, link, error, upstream_error}}
});

proxy.local_stop(function (r) { /* r = {ok, status: {...}} */ });

var s = proxy.local_status();   // the same status object, synchronously
```

`start` on an already-running proxy only restores its entry (the domain is then
optional). `stop` removes the entry and returns to a direct connection only when
that entry was the active one, so a proxy the user added by hand is never
disturbed; it runs when the plugin is disabled or unloaded, but not when the app
merely goes to the background. `local_status` is synchronous because it only
reads state the client already holds, which is what a settings row needs; it is
`{ok: false, running: false, error}` on a build without this bridge.

`active` says the entry is the one Telegram is using; `connections` and
`upstreams` say whether traffic is actually flowing. They are reported, never
guessed, which is what lets a plugin tell "connected" from "started and waiting".
`upstream_error` carries the last failure from the tunnel.

The `tg_ws_proxy` plugin in `js/` is the reference user of this API.

---

## 13. Text formatting

```js
var parsed = client_utils.parse_text("<b>Bold</b>, <i>Italic</i>, <a href='https://example.com'>Link</a>", "HTML");
// {message: "Bold, Italic, Link", entities: [{type, offset, length, url?}, ...]}

var cap = client_utils.parse_text("**Bold**", "Markdown", true);   // is_caption → key "caption"
// extera_utils.text_formatting.parse_text is the same function.
```

`TLEntityType`: `BOLD`, `ITALIC`, `UNDERLINE`, `STRIKETHROUGH`, `SPOILER`,
`CODE`, `PRE`, `TEXT_LINK`, `BLOCKQUOTE`, `CUSTOM_EMOJI`.

HTML: `<b>`, `<strong>`, `<i>`, `<em>`, `<u>`, `<ins>`, `<s>`, `<del>`,
`<strike>`, `<code>`, `<pre language="...">`, `<spoiler>`, `<tg-spoiler>`,
`<blockquote>`, `<a href>`, `<emoji id>`, `<br>`; the XML five and numeric
character references.

Markdown: `**bold**`, `*bold*`, `_italic_`, `__underline__`, `~~strike~~`,
`~strike~`, `||spoiler||`, `` `code` ``, ```` ```lang … ``` ````, `[text](url)`,
`![alt](tg://emoji?id=123)`, `> quote`, `**> quote`.

Entities are UTF-16 offsets, which is what both JavaScript and the host index by.

`RawEntity` is exported too (`extera_utils.text_formatting.RawEntity({
offset, length, type, url, language, document_id, collapsed})`), the
intermediate form the SDK converts to `TLRPC`; use it when a plugin builds
entities by hand.

`TLRPC.TL_messageEntity*` classes exist as plain records (`Bold`, `Italic`,
`Underline`, `Strike`, `Strikethrough`, `Spoiler`, `Code`, `Pre`, `TextUrl`,
`Blockquote`, `CustomEmoji`) so an export that builds an entity by hand keeps its
shape. `send_message` reads `offset`/`length`/`type` off whatever it is given and
those take precedence over `parse_mode`.

---

## 14. Bulletins and dialogs

```js
ui.bulletin.show_info("Information.");
ui.bulletin.show_error("Something failed.");
ui.bulletin.show_success("Done!");
ui.bulletin.show_two_line("Download complete", "Saved to gallery.");
ui.bulletin.show_with_button("Settings updated.", null, "Configure", function () { ... });
ui.bulletin.show_undo("Moved to trash.", {on_undo: undoFn, on_action: deleteFn});
ui.bulletin.show_copied_to_clipboard();
ui.bulletin.show_link_copied();
ui.bulletin.show_file_saved_to_gallery(false, 1);
ui.bulletin.show_file_saved_to_downloads("MUSIC", 1);
// ui.bulletin.BulletinHelper.show_info(...) is the same function.
```

Durations: `ui.bulletin.DURATION_SHORT` (1500), `DURATION_LONG` (2750),
`DURATION_PROLONG` (5000).

```js
var b = AlertDialogBuilder(activity);
b.set_title("My Plugin");
b.set_message("Important message.");
b.set_positive_button("OK", function (builder, which) { builder.dismiss(); });
b.set_negative_button("Cancel", function (builder, which) { builder.dismiss(); });
b.set_cancelable(true);
b.show();
```

Types: `AlertDialogBuilder.ALERT_TYPE_MESSAGE`, `ALERT_TYPE_LOADING`,
`ALERT_TYPE_SPINNER`. Button ids passed to a listener:
`BUTTON_POSITIVE`, `BUTTON_NEGATIVE`, `BUTTON_NEUTRAL`.

Methods: `set_title`, `set_message`, `set_items(items, listener)`,
`set_positive_button`, `set_negative_button`, `set_neutral_button`,
`set_on_cancel_listener`, `set_on_dismiss_listener`, `set_cancelable`,
`set_canceled_on_touch_outside`, `set_progress(0..100)`, `create()`, `show()`,
`dismiss()`, `get_dialog()`, `get_button()`.

`activity` is accepted for shape and ignored: iOS presents from the current
screen. The `listener(builder, which)` signature is preserved — the builder is
how a callback dismisses its own dialog. Appearance setters with no iOS
counterpart (`set_top_image`, `set_blurred_background`, `make_button_red`, …) are
accepted and ignored, so a ported dialog still shows, just plainer.

---

## 15. Files: file_utils

```js
file_utils.get_plugins_dir();     // the plugin's own folder — the writable root
file_utils.get_cache_dir();
file_utils.get_files_dir();
file_utils.get_images_dir();
file_utils.get_videos_dir();
file_utils.get_audios_dir();
file_utils.get_documents_dir();
file_utils.ensure_dir_exists(path);
file_utils.read_file(path);                  // string, or null
file_utils.write_file(path, "text");
file_utils.read_file_bytes(path);            // base64 string, or null
file_utils.write_file_bytes(path, base64);
file_utils.list_dir(path, {recursive: true, include_files: true, extensions: [".json"]});
file_utils.delete_file(path);
file_utils.file_exists(path);
```

`list_dir` also takes the SDK's positional form:
`list_dir(path, recursive, include_files, include_dirs, extensions)`.

`read_file_bytes`/`write_file_bytes` carry **base64 text**, not a byte array: a
byte array cannot cross the string bridge. Document that in a ported plugin
rather than pretending `bytes(...)` works.

Every path is confined to the app's own directories through the host, so a
plugin cannot reach outside them.

`FilesController` keeps its shape (`SUPPORT_ICONS`, `Place`, `FileInfo`,
`OnClickArgs`, the three exception types, `register`/`unregister`) for import
lines and enum references. `SUPPORT_ICONS` is `false` and `register` logs that
iOS has no file-open interception, so a plugin's own "not supported" branch
takes over instead of the handler silently never firing.

---

## 16. Appearance hooks

These are additions, not SDK surface. On Android the same effects came from
hooking obfuscated classes with Xposed; iOS has no such surface, so the screen
asks the plugin for a value while it is being built, and the client applies it
with its own palette and animation code.

A plugin implements the method and the host calls it. There is nothing to
register.

| Callback | Signature | Answers |
|---|---|---|
| `on_attach_menu_hook` | `(account, {keys}, extra)` | array of keys to keep from the attachment menu |
| `on_settings_rows_hook` | `(account, {keys}, extra)` | array of keys to keep from the settings tab |
| `on_message_inserted` | `(account, message, extra)` | animation object (see below) |
| `on_name_colors` | `(account, null, extra)` | `{main, secondary?, names?, avatars?, stories?, dialogs?, profiles?}` |
| `on_theme_colors` | `(account, null, extra)` | same shape plus `outgoing?` |
| `on_message_details` | `(account, message, extra)` | `[{title, value}, ...]` |
| `on_hide_message` | `(account, message, extra)` | `true` to drop the row |
| `on_allow_screenshots` | `(account, null, extra)` | `true` to allow screenshots everywhere |

`extra` carries `account` and, where a chat is known, `peer`. `message` is the
same field-object shape the update hooks receive. The attach-menu and
settings-row answers may only name keys that were offered — a key the plugin
never saw is ignored, so a plugin cannot hide something that was not in front of
it. Colours are `0xRRGGBB` numbers; an absent flag means "on"; an absent
`secondary` means "no gradient".

Insertion animation object (all fields optional except `duration`):

```js
{
    duration: 400,        // ms
    delay: 0,
    alpha: 0,             // alpha to start from, default 1
    scaleX: 0.8, scaleY: 0.8,
    scaleToX: 1, scaleToY: 1,
    translationX: 0, translationY: 0,
    rotationZ: 0, rotationX: 0, rotationY: 0,
    curve: "decelerate",  // linear|decelerate|accelerate|accelerateDecelerate|overshoot|spring
    overshoot: 0,
    rotationKeyframes: [0, 10, -10, 0]
}
```

`extra` for `on_message_inserted` also carries `isDate`, `width`, `height`. The
first plugin that answers wins for the message-insertion, name-colour,
theme-colour, and hide-message hooks — two plugins cannot both animate the same
row or own the same palette.

If a plugin changes a colour after the screen was drawn, it calls
`__extera.notifyAppearanceChanged()` (`this.set_setting(..., true)` does it too)
and the palette is rebuilt.

---

## 17. Saved deleted messages

A plugin can keep a copy of a message the user deletes, so the row stays in the
chat after the message is gone from Telegram.

`on_messages_will_be_deleted(account, {messages}, extra)` fires **just before**
the client removes messages the user deleted from this device. The server never
announces those (`messages.deleteMessages` answers only `affectedMessages`), so
this is the only point where the text still exists. Messages deleted by someone
else arrive as the ordinary `updateDeleteMessages` /
`updateDeleteChannelMessages` / `updateDeleteScheduledMessages` updates, so a
plugin that wants both registers both — that is what `UPDATE_HOOKS` in
`re_extera_dex` does.

Keep the copies wherever you like (a JSON file under
`file_utils.get_plugins_dir()` survives re-signing). Then answer two queries:

```js
// The rows the client should draw in this chat.
on_deleted_messages(account, {peer_id}, extra) {
    return [{
        id: 830646,          // original message id, Int32, non-zero
        date: 1735689600,    // Unix seconds, non-zero
        text: "the text",
        media_kind: "photo", // optional, shown when there is no text; "none"/"" means nothing
        sender_id: 123456,   // optional
        is_out: false,
    }];
}

// The user deleted the saved row in the client; drop the copy.
on_forget_deleted_messages(account, {peer_id, message_ids}, extra) {
    // remove each id from your store and rebuild any cache you keep
}
```

The client asks `on_deleted_messages` once per chat and only when at least one
plugin implements it. Answers from every listening plugin are concatenated and
de-duplicated by `(peer_id, id)`. A row without a usable `id` or `date` is
dropped — a zero would place it at the bottom of the chat. `peer_id` is
`PeerId.toInt64()`; a channel is `channel_id + 2 * 2^32`, and comparing it with
`update.message.peer_id` from an update hook works directly.

The drawn row is the same as a real message but marked deleted: slightly
transparent, with a red trash icon before the time. It is selectable like any
other message, so "select it, press Delete" removes it — the client calls
`on_forget_deleted_messages` with its id, then rebuilds the list. That is the
only way a saved row can be removed, because it exists nowhere but the plugin's
own store.

---

## 18. Logging

```js
this.log("loaded");
android_utils.log({some: "object"});   // non-primitives are inspected
```

The log is one file for every plugin (`Library/extera-plugins.log`), readable
from the client's plugin screen. A value that is not a primitive is rendered as
JSON, so `this.log(update)` is a usable way to inspect a payload.

A throw inside a plugin callback is caught by the runtime and logged against the
plugin id; it never escapes into the client. That means a plugin whose code threw
looks subscribed and does nothing — check the log first when a hook seems dead.

---

## 19. Android-only surfaces

These exist so an import line or an enum reference resolves. Where an equivalent
is possible on iOS it is real and noted; where it is not, the call logs rather
than pretending:

| Surface | Behaviour |
|---|---|
| `hook_utils.find_class` | **real**: resolves a loaded Objective-C class and returns a handle that can `.hook(selector, hook)`. Unknown names return `null`. |
| `hook_utils.get_private_field` / `set_private_field` / static variants | log and return `null` / `false`; a Swift property not exposed with `@objc` cannot be reached by name |
| Xposed-style `MethodHook` / `HookFilter`, `find_class(...).hook(...)` | **real** on Objective-C methods: the host swizzles the selector, runs `before`, calls the original unless `before` replaced the result, then runs `after` with `getResult()` set. A signature it cannot forward (struct/primitive args, primitive return) is refused with the type encoding, not installed with a wrong ABI. |
| `intents.IntentsManager` | **real**: `new_global_before_handler` / `new_global_after_handler` match opened URLs by scheme/host/path/query and run by ascending priority; a before-handler returning `true` stops the URL from opening. `send`/`startActivity` log and return `false`. |
| `extera_utils.classes.jclassbuilder` / `makeInstance` | **real**: builds an Objective-C subclass at runtime (`objc_allocateClassPair` + `class_addMethod`, or `class_replaceMethod` for a method the superclass already implements) and instantiates it. The arity comes from the JavaScript function the plugin supplied; only "receiver, ≤2 object args, object return" is representable. |
| `extera_utils.classes` decorators (`java_subclass`, `joverride`, `jmethod`, …) | identity functions that record the declaration for `jclassbuilder` |
| `client_utils.get_messages_controller` / `get_contacts_controller` / `get_user_config` / `get_media_data_controller` / `get_notifications_settings` / `get_queue_by_name` | **real** proxies over host bridges (see §20) |
| `client_utils.get_last_fragment`, `get_account_instance`, `get_connections_manager`, `send_request`, and the other controller getters | return `null` and log once, so a plugin's own guard takes the safe branch |
| `NotificationCenterDelegate` | instantiates; there is no notification centre to observe |
| `FilesController.register` | returns a token and logs that nothing will fire |
| `elyx.mvel_execute`, `gen`, `gen2` | throw with a clear reason; MVEL and the Java-proxy generators have no iOS counterpart |

`TLRPC` carries the message-entity classes and nothing else.

---

## 20. Controller proxies

`client_utils.get_*` that only ever read data a plugin can be given are backed by
real host calls and answer asynchronously, in the same callback shape as the HTTP
bridges. The method names are ours, not Android's: a ported plugin reaches the
same data through `get_messages(peer_id)` rather than a Java call.

```js
var messages = client_utils.get_messages_controller();
messages.get_messages(peer_id, 50, function (r) {
    // r = {ok, messages: [{id, peer_id, date, text, out, has_media, action, ...}, ...]}
});

var contacts = client_utils.get_contacts_controller();
contacts.get_peer(peer_id, function (r) { /* r = {ok, peer: {...} | null} */ });

var cfg = client_utils.get_user_config();
cfg.getClientUserId(function (r) { /* r = {ok, peer_id} */ });
cfg.getCurrentAccount();   // the resolved numeric account id

var media = client_utils.get_media_data_controller();
media.get_media(peer_id, 50, function (r) { /* r = {ok, media: [...]} */ });

var queue = client_utils.get_queue_by_name("name");
queue.run(fn); queue.run_after(fn, 250);
```

`get_messages_controller().send_message(peer, text, options)` forwards to the
plugin's own `send_text` and is fire-and-forget, like the SDK's send.
`delete_messages` logs that a message is deleted from the chat UI, not through a
controller, and answers `{ok: false}`. `get_notifications_settings().get` answers
peer-profile data, which is what a plugin reads it for.

A peer id on the bridge is `PeerId.toInt64()` — the client's own packed form, the
same number `pluginMessageDetailsJSON` reports and `send_message` expects. It is
**not** Telegram's `-100…` channel marking: that is a Bot API convention the
client never uses internally, and a peer id read from a hook has to be usable in
a send, so both directions go through the same codec and round-trip. Pass a peer
id you got from a hook back into any bridge call unchanged.

---

## 21. Intents

`intents.IntentsManager` registers global before/after handlers for URLs the app
opens — `tg://`, `https://t.me`, deeplinks, anything the OS hands the client. The
URL is parsed, the handlers are matched against it by scheme/host/path/query,
sorted by ascending priority, and called with the values their own signature names.

```js
var IM = intents.IntentsManager;

var handle = IM.new_global_before_handler(function (host, id) {
    this.log("chat " + id);
    return true;                 // stop the URL from opening
}, {scheme: "tg", host: "chat", required_path_args_names: ["id"]});

var after = IM.new_global_after_handler(function (host) {
    this.log("opened " + host);
}, {scheme: "https", host: "t.me"});

handle.unhandle();               // remove one
IM.unhandle(after.handler_id);   // remove by id
```

Filters: `scheme`, `host`, `path` (a leading `/` is added if missing, and
`{var}` templates capture their values), `required_path_args_names` (in practice
required **query** argument names), `priority` (lower runs first). `action`,
`type`, `categories`, `whitelist_flags`, `blacklist_flags` are accepted and match
against the URL's derived `Intent` values; an opened link is `ACTION_VIEW` with no
type or categories unless the URL mapped one.

A **before** handler that returns `true` stops the remaining before handlers *and*
the client's own handling of the URL — the iOS form of `param.setResult(true)`.
An **after** handler cannot stop anything; it runs once the URL has been handled.

The callback is called with only the parameters it names: `intent`, `scheme`,
`host`, `path`, `query_args`, `action`, `flags`, `type`, `categories`, plus any
query argument or path-template variable by name. A function with no readable
signature receives the whole context object (the `**kwargs` case); a function that
names `...args` receives the standard positional bundle.

`IM.parse(url)` returns `{scheme, host, path, query}` — the same shape a handler
sees. `IM.unhandle(id)` throws a `HandlerNotRegistered` error for an unknown id.
`IM.send` / `IM.startActivity` have no iOS meaning (this app has no intents to send
to another app) and log.

The host calls `__extera.dispatchUrlIntent(url)` before opening and
`__extera.dispatchUrlIntentAfter(url)` after; the client wires the first into
`AppDelegate.handleOpenURL`, so a before handler that returns `true` prevents the
open.

---

## 22. Porting checklist

1. Drop the `from … import …` lines; the names are globals — **except**
   `parse_text` and `SimpleSettingFactory`, which live only under
   `client_utils` / `ui.settings` (see §8). Qualify those two by hand.
2. `def` → `class P extends BasePlugin { … }`; `self` → `this`.
3. Keyword arguments → one trailing options object: `send_text(peer, "x", parse_mode="HTML")` → `send_text(peer, "x", {parse_mode: "HTML"})`.
4. Metadata stays as literal top-level assignments.
5. `isinstance`, list comprehensions, `str.format` → the JavaScript equivalents.
6. Register every hook you implement in `on_plugin_load`.
7. Guard controller getters — they answer `null` here.
8. `parse_mode` in one place: the JS parser is the same one `client_utils.parse_text` uses.
9. Test with `node js/test` — `bootstrap.test.js` runs the real `bootstrap.js` against a fake host with the exact bridge shape the Swift side implements.

---

## 23. JS ↔ Swift bridge (host internals)

Not plugin API. It is documented because a plugin's capability set is exactly
this list, and because `js/test/bootstrap.test.js` is the contract check for it.

`__host` members the bootstrap calls (all arguments strings except numbers):

| Member | Returns |
|---|---|
| `log(pluginId, text)` | — |
| `getSetting(pluginId, key)` | value or null |
| `setSetting(pluginId, key, value, reload)` | — |
| `exportSettings`, `importSettings` | object / — |
| `addHook(pluginId, name, matchSubstring)` | — |
| `addOnSendMessageHook(pluginId)` | — |
| `addMenuItem`, `removeMenuItem` | itemId / — |
| `sendText`, `sendFile`, `editMessage` | — |
| `showBulletin`, `showAlert`, `dismissAlert` | — |
| `fileOp(pluginId, op, path, payload)` | JSON text |
| `selectedAccount(pluginId)` | number |
| `appVersion(pluginId)` | string |
| `copyToClipboard`, `openUrl` | — / bool |
| `openSettingLink(pluginId, alias)` | — |
| `pluginDirectory(pluginId)`, `moduleDirectory(pluginId)` | path |
| `readModule(pluginId, path)`, `moduleExists(pluginId, path)` | text / bool |
| `schedulePlugin(pluginId, delayMs, token)` | — |
| `themeColors(pluginId, namesJSON)` | JSON text |
| `classExists(pluginId, className)` | bool |
| `installSwizzle(pluginId, class, selector, isClassMethod, beforeToken, afterToken)` | reason or null |
| `buildClass(pluginId, superclassName, methodsJSON)` | class name, or `"!" + reason` |
| `makeInstanceClass(pluginId, className)` | object handle or null |
| `httpGet`, `httpRequest`, `proxyList`, `proxyAdd`, `proxyRemoveAll`, `localProxy`, `ownPeerId`, `peerInfo`, `chatMessages` | — (answers through `__extera.resolveBridge(token, json)`) |
| `localProxyStatus(pluginId)` | JSON text (synchronous) |

The asynchronous members answer by calling back into the context with
`__extera.resolveBridge(token, JSON)`; a plugin-facing helper stores the
callback under the token and returns it.

Swift entry points the manager exposes (JS function → Swift method): `runHook`,
`query`, `hasHook`, `collectSettings`, `collectSubSettings`, `collectMenuItems`,
`runMenuItem`, `invokeSettingCallback`, `runScheduled`, `runCallback`,
`resolveBridge`, `callLifecycle`, `finalize`, `register`,
`dispatchUrlIntent`, `dispatchUrlIntentAfter`, `runSwizzleCallback`.

Members of `__extera` a plugin is not meant to call, listed so the surface is
complete: `setIdentity`, `id`, `name`, `instance`, `api`, `LIFECYCLE`,
`normalizeResult`, `callLifecycleJSON`, `holdBridge`, `requestHttp`,
`requestProxyList`, `requestProxyAdd`, `requestProxyRemoveAll`, `requestOwnPeerId`,
`parseText`, `fileValue`, `setSelectedAccount`, `selectedAccount`, `hookAccount`,
`resolveAccount`, `settingKey`, `makeAccountClient`, `bulletinJson`,
`holdCallback`, `runCallback`, `copyToClipboard`, `openUrl`, `appVersion`,
`themeColors`, `hasHook`, `controllerRequest`, `resolveClass`, `makeClassHandle`,
`installHook`, `runSwizzleHook`, `runSwizzleCallback`, `buildClass`,
`makeInstanceClass`.
`bulletinJson` is the richer bulletin form behind `ui.bulletin`: it takes one
object whose callbacks are already tokens, and the host draws the title line,
button or undo action from it.

Everything on the boundary is a JSON string. No JS object, function, or promise
crosses it, and no Swift object is retained by a plugin's context.
