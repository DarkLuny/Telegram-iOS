#!/usr/bin/env python3
"""Turn the upstream tree into a sideload-installable build.

Two separate problems make a stock build die or stall after re-signing
with a free Apple ID:

1. Entitlements. `Telegram/BUILD` adds every right the real App Store
   Telegram has (iCloud, Siri, CarPlay, Apple Pay, PushKit VoIP,
   communication notifications, filtering, Sign in with Apple,
   associated domains). A free provisioning profile grants none of them,
   and iOS kills the process at launch when the signature asks for a
   right the profile does not carry -- tap the icon, back to the home
   screen, no crash log worth reading.

2. App Group. Free certificates cannot carry `group.<bundleId>`, so
   `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil.
   Upstream then shows the "Error 2" alert instead of starting, and
   creating the background URLSession with a dead
   `sharedContainerIdentifier` raises an exception outright.

The patch keeps `aps-environment` + `application-identifier` +
`group.<bundleId>` (the set a working sideload build ships) and makes the
main app fall back to its Documents directory when the group is missing.
"""

import io
import sys

BUILD_PATH = "Telegram/BUILD"
APP_DELEGATE_PATH = "submodules/TelegramUI/Sources/AppDelegate.swift"

# --- 1. Entitlements -------------------------------------------------------

OLD_TEMPLATE = """        aps_fragment,
        app_groups_fragment,
        siri_fragment,
        associated_domains_fragment,
        icloud_fragment,
        apple_pay_merchants_fragment,
        unrestricted_voip_fragment,
        carplay_fragment,
        communication_notifications_fragment,
        notification_filtering_fragment,
        signin_fragment,
        background_gpu_fragment,
"""

NEW_TEMPLATE = """        aps_fragment,
        app_groups_fragment,
"""

# --- 1b. Drop the app extensions -------------------------------------------
# Every extension carries its own entitlements and its own provisioning
# profile; a free Apple ID cannot sign them, and Sideloadly then either fails
# or ships an app whose extension launch kills the host. The working sideload
# build has no PlugIns at all.

OLD_EXTENSIONS = """    extensions = select({
        ":disableExtensionsSetting": [],
        "//conditions:default": [
            ":ShareExtension",
            ":NotificationContentExtension",
            ":NotificationServiceExtension" + notificationServiceExtensionVersion,
            ":IntentsExtension",
            ":WidgetExtension",
            ":BroadcastUploadExtension",
        ],
    }),
"""

NEW_EXTENSIONS = """    extensions = [],
"""

# --- 2a. Background URLSession needs a real App Group ----------------------

OLD_SESSION = """        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = appGroupName
"""

NEW_SESSION = """        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // A re-signed build without the App Group entitlement has no shared
        // container; handing that identifier to a background session raises.
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) != nil {
            configuration.sharedContainerIdentifier = appGroupName
        }
"""

# --- 2b. Fall back to Documents when the group is unavailable --------------

OLD_GROUP_GUARD = """        guard let appGroupUrl = maybeAppGroupUrl else {
            self.mainWindow?.presentNative(UIAlertController(title: nil, message: "Error 2", preferredStyle: .alert))
            return true
        }
"""

NEW_GROUP_GUARD = """        let appGroupUrl: URL
        if let existing = maybeAppGroupUrl {
            appGroupUrl = existing
        } else {
            // No App Group entitlement (free Apple ID / sideload re-sign):
            // store under Documents so the app can still start.
            let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fallbackUrl = documentsUrl.appendingPathComponent("telegram-shared", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallbackUrl, withIntermediateDirectories: true, attributes: nil)
            appGroupUrl = fallbackUrl
        }
"""


def patch(path, old, new, required=True):
    with io.open(path, encoding="utf-8") as handle:
        text = handle.read()
    if old not in text:
        if new.strip() and new in text:
            print("already patched, skipping: %s" % path)
            return False
        if required:
            raise SystemExit("anchor not found in %s:\n%s" % (path, old))
        print("already patched, skipping: %s" % path)
        return False
    if text.count(old) != 1:
        raise SystemExit("anchor is not unique in %s (%d matches)" % (path, text.count(old)))
    with io.open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text.replace(old, new))
    print("patched %s" % path)
    return True


def main():
    patch(BUILD_PATH, OLD_TEMPLATE, NEW_TEMPLATE)
    patch(BUILD_PATH, OLD_EXTENSIONS, NEW_EXTENSIONS)
    patch(APP_DELEGATE_PATH, OLD_SESSION, NEW_SESSION)
    patch(APP_DELEGATE_PATH, OLD_GROUP_GUARD, NEW_GROUP_GUARD)
    print("sideload patch applied")


if __name__ == "__main__":
    main()
