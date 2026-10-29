/*
 * exteraGram-compatible plugin bootstrap for Telegram iOS.
 *
 * This file is not shipped as a resource: `PluginBootstrap.swift` embeds it as a
 * string and evaluates it in every plugin's JSContext before the plugin source.
 * Keeping it here lets `node js/test` run the same code the app runs.
 *
 * The host (Swift) provides a single object, `__host`, with these members:
 *
 *   __host.log(pluginId, text)
 *   __host.getSetting(pluginId, key)
 *   __host.setSetting(pluginId, key, value, reload)
 *   __host.exportSettings(pluginId) / importSettings(pluginId, values, reload)
 *   __host.addHook(pluginId, name, matchSubstring)
 *   __host.addOnSendMessageHook(pluginId)
 *   __host.addMenuItem(pluginId, itemJson) -> itemId
 *   __host.removeMenuItem(pluginId, itemId)
 *   __host.sendText(pluginId, peerId, text, optionsJson)
 *   __host.sendFile(pluginId, kind, peerId, path, optionsJson)
 *   __host.showBulletin(pluginId, kind, text)
 *   __host.pluginDirectory(pluginId)
 *   __host.schedulePlugin(pluginId, delayMs, token)
 *
 * `js/test/bootstrap.test.js` fails on a call this list does not cover, and
 * `_bridge_check.py` compares it against `PluginLoader.swift`, so the two sides
 * cannot drift apart without a test noticing.
 *
 * The API surface mirrors exteraGram's Python SDK (BasePlugin, HookResult,
 * HookStrategy, MenuItemData, MenuItemType, AppEvent, the ui.settings controls)
 * because that is the contract plugin authors already know. The Python runtime
 * itself cannot exist on iOS: exteraGram's plugins reach into Java classes via
 * reflection and Xposed hooks, and there are no Java classes here. What maps is
 * the shape of the API, not the implementation.
 */

var __extera = (function () {
    'use strict';

    var pluginId = null;
    var pluginName = null;
    var registeredHooks = [];
    var sendHookEnabled = false;
    var menuItems = {};
    var scheduled = {};
    var scheduledCounter = 0;

    function host() {
        return __host;
    }

    function bridgeMissing(name) {
        var h = host();
        if (!h || typeof h[name] !== 'function') {
            throw new Error('host bridge is missing ' + name);
        }
        return h[name].bind(h);
    }

    // --- enums ------------------------------------------------------------

    var HookStrategy = {
        DEFAULT: 'default',
        CANCEL: 'cancel',
        MODIFY: 'modify',
        MODIFY_FINAL: 'modify_final',
    };

    var AppEvent = {
        START: 'start',
        STOP: 'stop',
        PAUSE: 'pause',
        RESUME: 'resume',
    };

    var MenuItemType = {
        MESSAGE_CONTEXT_MENU: 'message_context_menu',
        DRAWER_MENU: 'drawer_menu',
        MAIN_MENU: 'main_menu',
        CHAT_ACTION_MENU: 'chat_action_menu',
        PROFILE_ACTION_MENU: 'profile_action_menu',
    };

    // --- HookResult -------------------------------------------------------

    function HookResult(options) {
        options = options || {};
        this.strategy = options.strategy || HookStrategy.DEFAULT;
        this.request = options.request !== undefined ? options.request : null;
        this.response = options.response !== undefined ? options.response : null;
        this.update = options.update !== undefined ? options.update : null;
        this.updates = options.updates !== undefined ? options.updates : null;
        this.params = options.params !== undefined ? options.params : null;
    }

    HookResult.cancel = function () {
        return new HookResult({ strategy: HookStrategy.CANCEL });
    };

    HookResult.modify = function (field, value) {
        var result = new HookResult({ strategy: HookStrategy.MODIFY });
        result[field] = value;
        return result;
    };

    // --- MenuItemData -----------------------------------------------------

    function MenuItemData(options) {
        options = options || {};
        this.menu_type = options.menu_type;
        this.text = options.text;
        this.on_click = options.on_click;
        this.item_id = options.item_id || null;
        this.icon = options.icon || null;
        this.subtext = options.subtext || null;
        this.condition = options.condition || null;
        this.priority = options.priority === undefined ? 0 : options.priority;
    }

    // --- ui.settings controls --------------------------------------------
    //
    // exteraGram returns dataclass instances and the host renders them. Here the
    // controls are plain objects; the Swift side reads their fields.
    //
    // Each control is a function that *returns* its object, so it works both as
    // `new Switch(...)` (what ported plugins write) and `Switch(...)`.

    function control(type, options, fields) {
        var result = { type: type };
        Object.keys(fields).forEach(function (key) {
            result[key] = fields[key];
        });
        return result;
    }

    function textOrNull(value) {
        return value === undefined || value === null ? null : value;
    }

    function callbackOrNull(value) {
        return typeof value === 'function' ? value : null;
    }

    function Header(options) {
        options = options || {};
        return control('header', options, {
            text: options.text === undefined ? '' : options.text,
        });
    }

    function Divider(options) {
        options = options || {};
        return control('divider', options, {
            text: textOrNull(options.text),
        });
    }

    function Switch(options) {
        options = options || {};
        return control('switch', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? false : options.default,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Selector(options) {
        options = options || {};
        return control('selector', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? 0 : options.default,
            items: options.items || [],
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Input(options) {
        options = options || {};
        return control('input', options, {
            key: options.key,
            text: options.text,
            default: options.default === undefined ? '' : options.default,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            on_change: callbackOrNull(options.on_change),
            on_long_click: callbackOrNull(options.on_long_click),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function EditText(options) {
        options = options || {};
        return control('edit_text', options, {
            key: options.key,
            hint: options.hint === undefined ? '' : options.hint,
            default: options.default === undefined ? '' : options.default,
            multiline: !!options.multiline,
            max_length: options.max_length === undefined ? 0 : options.max_length,
            mask: textOrNull(options.mask),
            on_change: callbackOrNull(options.on_change),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Text(options) {
        options = options || {};
        return control('text', options, {
            text: options.text,
            subtext: textOrNull(options.subtext),
            icon: textOrNull(options.icon),
            accent: !!options.accent,
            red: !!options.red,
            on_click: callbackOrNull(options.on_click),
            on_long_click: callbackOrNull(options.on_long_click),
            create_sub_fragment: callbackOrNull(options.create_sub_fragment),
            link_alias: textOrNull(options.link_alias),
        });
    }

    function Custom(options) {
        options = options || {};
        return control('custom', options, {
            item: options.item || null,
            view: options.view || null,
            factory: options.factory || null,
            factory_args: options.factory_args || [],
            on_click: callbackOrNull(options.on_click),
            on_long_click: callbackOrNull(options.on_long_click),
            create_sub_fragment: callbackOrNull(options.create_sub_fragment),
            link_alias: textOrNull(options.link_alias),
        });
    }

    // --- BasePlugin -------------------------------------------------------

    function BasePlugin() {
        this.log = function (message) {
            bridgeMissing('log')(pluginId, String(message));
        };

        this.getName = function () {
            return pluginName;
        };

        this.getId = function () {
            return pluginId;
        };

        this.get_setting = function (key, fallback) {
            var value = bridgeMissing('getSetting')(pluginId, key);
            if (value === null || value === undefined) {
                return fallback === undefined ? null : fallback;
            }
            return value;
        };

        this.set_setting = function (key, value, reload_settings) {
            bridgeMissing('setSetting')(pluginId, key, value, !!reload_settings);
        };

        this.export_settings = function () {
            return bridgeMissing('exportSettings')(pluginId);
        };

        this.import_settings = function (settings, reload_settings) {
            bridgeMissing('importSettings')(pluginId, settings, !!reload_settings);
        };

        this.add_hook = function (name, match_substring, priority) {
            registeredHooks.push(name);
            // exteraGram's second argument lets one registration cover a whole
            // request family (`messages.`). It has to reach the host, or a plugin
            // using it would silently never fire.
            bridgeMissing('addHook')(pluginId, name, !!match_substring);
        };

        this.add_on_send_message_hook = function () {
            sendHookEnabled = true;
            bridgeMissing('addOnSendMessageHook')(pluginId);
        };

        this.add_menu_item = function (data) {
            var itemId = data.item_id || (pluginId + '_' + Math.random().toString(36).slice(2, 10));
            var payload = {
                item_id: itemId,
                menu_type: data.menu_type,
                text: data.text,
                icon: data.icon,
                subtext: data.subtext,
                condition: data.condition,
                priority: data.priority,
                plugin_id: pluginId,
            };
            bridgeMissing('addMenuItem')(pluginId, JSON.stringify(payload));
            menuItems[itemId] = data;
            return itemId;
        };

        this.remove_menu_item = function (itemId) {
            delete menuItems[itemId];
            bridgeMissing('removeMenuItem')(pluginId, itemId);
        };

        // Message helpers: the Swift host performs the actual enqueue.
        this.send_text = function (peerId, text, options) {
            bridgeMissing('sendText')(pluginId, peerId, text, JSON.stringify(options || {}));
        };

        this.send_photo = function (peerId, path, options) {
            bridgeMissing('sendFile')(pluginId, 'photo', peerId, path, JSON.stringify(options || {}));
        };

        this.send_document = function (peerId, path, options) {
            bridgeMissing('sendFile')(pluginId, 'document', peerId, path, JSON.stringify(options || {}));
        };

        this.send_video = function (peerId, path, options) {
            bridgeMissing('sendFile')(pluginId, 'video', peerId, path, JSON.stringify(options || {}));
        };

        this.send_audio = function (peerId, path, options) {
            bridgeMissing('sendFile')(pluginId, 'audio', peerId, path, JSON.stringify(options || {}));
        };

        this.show_bulletin = function (kind, text) {
            bridgeMissing('showBulletin')(pluginId, kind, text);
        };

        // The function stays here and the host only receives a token, because a
        // function cannot cross the bridge. `runScheduled(token)` is what the host
        // calls when the delay is over.
        this.run_on_queue = function (fn, delayMs) {
            if (typeof fn !== 'function') {
                throw new Error('run_on_queue expects a function');
            }
            scheduledCounter += 1;
            var token = 'q' + scheduledCounter;
            scheduled[token] = fn;
            bridgeMissing('schedulePlugin')(pluginId, delayMs || 0, token);
            return token;
        };

        this.get_plugin_directory = function () {
            return bridgeMissing('pluginDirectory')(pluginId);
        };
    }

    BasePlugin.prototype.create_settings = function () {
        return [];
    };

    // Optional lifecycle hooks a plugin may override; called only when present.
    var LIFECYCLE = ['on_plugin_load', 'on_plugin_unload', 'on_app_event',
                     'pre_request_hook', 'post_request_hook',
                     'on_update_hook', 'on_updates_hook', 'on_send_message_hook'];

    function callLifecycle(instance, name, args) {
        if (instance && typeof instance[name] === 'function') {
            return instance[name].apply(instance, args || []);
        }
        return undefined;
    }

    // --- registration -----------------------------------------------------

    function register(PluginClass) {
        if (typeof PluginClass !== 'function') {
            throw new Error('plugin default export must be a class extending BasePlugin');
        }
        var instance = new PluginClass();
        __extera.instance = instance;
        return instance;
    }

    // exteraGram instantiates the module's `Plugin` class itself; a ported plugin
    // therefore does not register anything explicitly. `finalize()` supplies that
    // behaviour: it instantiates `Plugin` (or whatever `__plugin_instance__`
    // already holds) when the plugin never called `register` itself.
    function finalize() {
        if (__extera.instance) {
            return true;
        }
        var existing = typeof __plugin_instance__ !== 'undefined' ? __plugin_instance__ : null;
        if (existing && typeof existing === 'object') {
            __extera.instance = existing;
            return true;
        }
        var PluginClass = typeof Plugin !== 'undefined' ? Plugin : null;
        if (typeof PluginClass === 'function') {
            __extera.instance = new PluginClass();
            return true;
        }
        return false;
    }

    function callLifecycleJSON(event, contextJSON) {
        var instance = __extera.instance;
        if (!instance || typeof instance[event] !== 'function') {
            return null;
        }
        var extra = contextJSON ? JSON.parse(contextJSON) : {};
        // exteraGram's lifecycle signatures differ: `on_app_event(event)` takes
        // the AppEvent value, the load/unload pair takes nothing, and the rest
        // are covered by `runHook`.
        var raw;
        if (event === 'on_app_event') {
            // The host spells the event `START`; `AppEvent.START` here is
            // `'start'`, and a ported plugin compares against that constant, so
            // the value is normalized before the plugin sees it.
            var appEvent = extra.event;
            if (typeof appEvent === 'string') {
                appEvent = appEvent.toLowerCase();
            }
            raw = instance[event].call(instance, appEvent);
        } else {
            raw = instance[event].call(instance);
        }
        if (raw === undefined || raw === null) {
            return null;
        }
        if (typeof raw === 'object') {
            return JSON.stringify(raw);
        }
        return JSON.stringify({ value: raw });
    }

    // --- settings collection ---------------------------------------------
    //
    // exteraGram renders whatever `create_settings()` returns and reads each
    // control's value from the plugin's stored settings by key. The Swift
    // renderer cannot call into JS for every row, so it asks for the whole list
    // once and reads `value` from it. A control without a key gets one derived
    // from its text, which is stable across launches because the text is.

    function settingKey(control, index) {
        if (control.key !== undefined && control.key !== null && control.key !== '') {
            return String(control.key);
        }
        var basis = control.text || control.hint || control.type;
        return String(basis).toLowerCase().replace(/[^a-z0-9]+/g, '_') + '_' + index;
    }

    function collectSettings() {
        var instance = __extera.instance;
        if (!instance || typeof instance.create_settings !== 'function') {
            return '[]';
        }
        var raw = instance.create_settings();
        if (!raw || typeof raw.length !== 'number') {
            return '[]';
        }
        var result = [];
        for (var i = 0; i < raw.length; i++) {
            var control = raw[i];
            if (!control || typeof control !== 'object' || typeof control.type !== 'string') {
                continue;
            }
            var copy = {};
            for (var key in control) {
                if (Object.prototype.hasOwnProperty.call(control, key) && typeof control[key] !== 'function') {
                    copy[key] = control[key];
                }
            }
            if (control.type === 'switch' || control.type === 'selector' ||
                control.type === 'input' || control.type === 'edit_text') {
                copy.key = settingKey(control, i);
                var stored = bridgeMissing('getSetting')(pluginId, copy.key);
                copy.value = (stored === null || stored === undefined) ? control['default'] : stored;
                copy.has_callbacks = typeof control.on_change === 'function' ||
                    typeof control.on_long_click === 'function';
            }
            result.push(copy);
        }
        return JSON.stringify(result);
    }

    // --- menu items -------------------------------------------------------

    // Menu items the host should show for one menu, in exteraGram's order.
    //
    // `condition` is a function, so it cannot be evaluated when the item is
    // registered: the host asks for the list each time a menu opens, passing the
    // context exteraGram gives the callback. A condition that throws hides the
    // item rather than breaking the menu.
    function collectMenuItems(menuType, contextJSON) {
        var context = contextJSON ? JSON.parse(contextJSON) : {};
        var result = [];
        for (var itemId in menuItems) {
            if (!Object.prototype.hasOwnProperty.call(menuItems, itemId)) {
                continue;
            }
            var data = menuItems[itemId];
            if (!data || data.menu_type !== menuType || typeof data.text !== 'string') {
                continue;
            }
            if (typeof data.condition === 'function') {
                var visible = false;
                try {
                    visible = !!data.condition(context);
                } catch (error) {
                    visible = false;
                }
                if (!visible) {
                    continue;
                }
            }
            result.push({
                item_id: itemId,
                text: data.text,
                subtext: data.subtext === undefined ? null : data.subtext,
                icon: data.icon === undefined ? null : data.icon,
                priority: data.priority === undefined ? 0 : data.priority,
            });
        }
        result.sort(function (a, b) { return b.priority - a.priority; });
        return JSON.stringify(result);
    }

    // Runs a menu item's click handler. The context is what the host knows about
    // the place the menu was opened from; the callback receives it as an object.
    function runMenuItem(itemId, contextJSON) {
        var data = menuItems[itemId];
        if (!data || typeof data.on_click !== 'function') {
            return;
        }
        data.on_click(contextJSON ? JSON.parse(contextJSON) : {});
    }

    // Calls a control callback by key, used when the user edits a setting. The
    // function object never crosses the bridge; the key does. `valueJSON` is the
    // new value, encoded so it can arrive through a string-only bridge.
    function invokeSettingCallback(key, kind, valueJSON) {
        var instance = __extera.instance;
        if (!instance || typeof instance.create_settings !== 'function') {
            return;
        }
        var value = valueJSON ? JSON.parse(valueJSON) : null;
        if (value !== null && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'value')) {
            value = value.value;
        }
        var raw = instance.create_settings() || [];
        for (var i = 0; i < raw.length; i++) {
            var control = raw[i];
            if (!control) {
                continue;
            }
            if (settingKey(control, i) !== key) {
                continue;
            }
            var fn = kind === 'long_click' ? control.on_long_click : control.on_change;
            if (typeof fn === 'function') {
                fn(value === undefined ? null : value);
            }
            return;
        }
    }

    // Runs a callback that `run_on_queue` registered. The host holds only the
    // token, so this is the only way the function can be reached again.
    function runScheduled(token) {
        var fn = scheduled[token];
        if (typeof fn !== 'function') {
            return;
        }
        delete scheduled[token];
        fn();
    }

    function normalizeResult(value, field) {
        if (value === null || value === undefined) {
            return { strategy: HookStrategy.DEFAULT, value: null };
        }
        if (typeof value !== 'object') {
            return { strategy: HookStrategy.DEFAULT, value: null };
        }
        var strategy = value.strategy || HookStrategy.DEFAULT;
        var payload = value[field];
        if (payload === null || payload === undefined) {
            payload = null;
        }
        return { strategy: strategy, value: payload };
    }

    // --- hook invocation --------------------------------------------------
    //
    // Swift passes a JSON-encoded event and gets back a JSON-encoded result.
    // Running the call here, rather than calling the method straight from
    // Swift, keeps `this` bound to the plugin instance and keeps every JS
    // object on the JS side: the only things crossing the bridge are strings.
    // `runHook` returns:
    //   { "strategy": "default" }                      nothing asked for
    //   { "strategy": "cancel" }                       request suppressed
    //   { "strategy": "modify", "payload": {...} }     replacement payload
    //   { "result": <JSON string> }                    for notify-type hooks

    function runHook(event, payloadJSON, contextJSON) {
        var instance = __extera.instance;
        if (!instance) {
            return JSON.stringify({ strategy: HookStrategy.DEFAULT });
        }
        var fn = instance[event];
        if (typeof fn !== 'function') {
            return JSON.stringify({ strategy: HookStrategy.DEFAULT });
        }
        var payload = payloadJSON ? JSON.parse(payloadJSON) : null;
        var extra = contextJSON ? JSON.parse(contextJSON) : {};

        var raw;
        switch (event) {
        case 'pre_request_hook':
            raw = fn.call(instance, extra.name, extra.account, payload);
            break;
        case 'post_request_hook':
            raw = fn.call(instance, extra.name, extra.account, payload, extra.error === undefined ? null : extra.error);
            break;
        case 'on_send_message_hook':
            raw = fn.call(instance, extra.account, payload);
            break;
        case 'on_update_hook':
            raw = fn.call(instance, extra.name, extra.account, payload);
            break;
        case 'on_updates_hook':
            // A batch crosses the bridge as `{"updates": [...]}`, because only a
            // dictionary fits the host's payload type. exteraGram hands the hook
            // the list itself, so unwrap it here.
            raw = fn.call(instance, extra.name, extra.account,
                (payload && payload.updates) || []);
            break;
        default:
            raw = fn.call(instance, payload, extra);
            break;
        }

        var result = normalizeResult(raw, extra.field || 'request');
        var out = { strategy: result.strategy };
        if (result.value !== null && typeof result.value === 'object') {
            out.payload = result.value;
        }
        return JSON.stringify(out);
    }

    return {
        setIdentity: function (id, name) {
            pluginId = id;
            pluginName = name;
        },
        name: function () { return pluginName; },
        id: function () { return pluginId; },
        bulletin: function (kind, text) {
            bridgeMissing('showBulletin')(pluginId, kind, String(text));
        },
        log: function (message) {
            bridgeMissing('log')(pluginId, String(message));
        },
        instance: null,
        register: register,
        finalize: finalize,
        callLifecycle: callLifecycle,
        callLifecycleJSON: callLifecycleJSON,
        normalizeResult: normalizeResult,
        runHook: runHook,
        runScheduled: runScheduled,
        collectSettings: collectSettings,
        collectMenuItems: collectMenuItems,
        runMenuItem: runMenuItem,
        invokeSettingCallback: invokeSettingCallback,
        LIFECYCLE: LIFECYCLE,
        api: {
            BasePlugin: BasePlugin,
            HookResult: HookResult,
            HookStrategy: HookStrategy,
            MenuItemData: MenuItemData,
            MenuItemType: MenuItemType,
            AppEvent: AppEvent,
            Header: Header,
            Divider: Divider,
            Switch: Switch,
            Selector: Selector,
            Input: Input,
            EditText: EditText,
            Text: Text,
            Custom: Custom,
        },
    };
})();

// The names plugins import in exteraGram are module-scope there. Expose the same
// names as globals so a plugin body compiles unchanged apart from its import lines.
var BasePlugin = __extera.api.BasePlugin;
var HookResult = __extera.api.HookResult;
var HookStrategy = __extera.api.HookStrategy;
var MenuItemData = __extera.api.MenuItemData;
var MenuItemType = __extera.api.MenuItemType;
var AppEvent = __extera.api.AppEvent;

var Header = __extera.api.Header;
var Divider = __extera.api.Divider;
var Switch = __extera.api.Switch;
var Selector = __extera.api.Selector;
var Input = __extera.api.Input;
var EditText = __extera.api.EditText;
var Text = __extera.api.Text;
var Custom = __extera.api.Custom;

// `ui.settings`, `client_utils`, `hook_utils` and `android_utils` are Python
// modules in exteraGram. Here they are plain objects so a ported plugin can keep
// its shape: `var settings = ui.settings; settings.Switch(...)`.
var ui = {
    settings: __extera.api,
    bulletin: {
        show_info: function (text) { __extera.bulletin('info', text); },
        show_error: function (text) { __extera.bulletin('error', text); },
        show_success: function (text) { __extera.bulletin('success', text); },
        show_simple: function (text) { __extera.bulletin('info', text); },
        show_two_line: function (title, text) { __extera.bulletin('info', title + ': ' + text); },
    },
};

var android_utils = {
    log: function (message) { __extera.log(message); },
};

var hook_utils = {
    // iOS has no Objective-C reflection surface exposed to plugins; these return
    // null rather than pretending to work, so a ported plugin degrades instead of
    // failing at load time.
    find_class: function () { return null; },
    get_private_field: function () { return null; },
    set_private_field: function () { return false; },
    get_static_private_field: function () { return null; },
    set_static_private_field: function () { return false; },
};