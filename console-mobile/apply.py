#!/usr/bin/env python3
"""Inject the Console tab into a RustDesk Flutter source tree.

Usage: python3 apply.py <path-to-checkout-root>

The script is idempotent: running it twice on the same tree is a no-op.
It expects console_page.dart / console_api.dart to be copied next to the
mobile pages by the caller (see android-aarch64.yml).
"""

import os
import re
import sys

APP_LABEL = "RustDesk 控制台"
APP_ID = "com.fengyun.rdconsole"


def patch_home_page(path):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    if "console_page.dart" in src:
        print("home_page.dart already patched")
        return

    import_line = "import 'console_page.dart';\n"
    marker = "import 'connection_page.dart';\n"
    if marker not in src:
        raise SystemExit("cannot find connection_page import in home_page.dart")
    src = src.replace(marker, marker + import_line, 1)

    anchor = "    _pages.add(SettingsPage());\n"
    if anchor not in src:
        raise SystemExit("cannot find SettingsPage anchor in home_page.dart")
    src = src.replace(anchor, anchor + "    _pages.add(ConsolePage());\n", 1)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("patched home_page.dart")


def patch_manifest(path):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()

    if 'android:label="%s"' % APP_LABEL not in src:
        src = src.replace('android:label="RustDesk"',
                          'android:label="%s"' % APP_LABEL, 1)
    if "usesCleartextTraffic" not in src:
        src = src.replace(
            "    <application\n",
            '    <application\n        android:usesCleartextTraffic="true"\n',
            1,
        )

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("patched AndroidManifest.xml")


def patch_styles(path):
    """Let Android 15/16 edge-to-edge layouts use landscape cutout areas."""
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    if "windowLayoutInDisplayCutoutMode" in src:
        print("%s already patched" % os.path.basename(os.path.dirname(path)))
        return

    item = ('        <item name="android:windowLayoutInDisplayCutoutMode">'
            'shortEdges</item>\n')
    for style_name in ("LaunchTheme", "NormalTheme"):
        pattern = re.compile(r'(<style name="%s"[^>]*>\n)' % style_name)
        src = pattern.sub(lambda match: match.group(1) + item, src, count=1)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("patched %s" % path)


def patch_gradle(path):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    if 'applicationId "%s"' % APP_ID in src and 'signingConfigs.console' in src:
        print("build.gradle already patched")
        return

    src = re.sub(r'applicationId\s+"com\.carriez\.flutter_hbb"',
                 'applicationId "%s"' % APP_ID, src, count=1)
    if 'signingConfigs.console' not in src:
        anchor = "    signingConfigs {\n"
        if anchor not in src:
            raise SystemExit("cannot find signingConfigs in build.gradle")
        console_config = anchor + (
            "      console {\n"
            "        keyAlias 'androiddebugkey'\n"
            "        keyPassword 'android'\n"
            "        storeFile file('console.keystore')\n"
            "        storePassword 'android'\n"
            "      }\n"
        )
        src = src.replace(anchor, console_config, 1)
        src = src.replace("signingConfig signingConfigs.release",
                          "signingConfig signingConfigs.console", 1)
    if 'applicationId "%s"' % APP_ID not in src or 'signingConfigs.console' not in src:
        raise SystemExit("failed to patch applicationId/signing in build.gradle")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("patched build.gradle")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    root = os.path.abspath(sys.argv[1])
    flutter = os.path.join(root, "flutter")

    pages = os.path.join(flutter, "lib", "mobile", "pages")
    home_page = os.path.join(pages, "home_page.dart")
    manifest = os.path.join(flutter, "android", "app", "src", "main",
                            "AndroidManifest.xml")
    gradle = os.path.join(flutter, "android", "app", "build.gradle")
    styles = [
        os.path.join(flutter, "android", "app", "src", "main", "res",
                     "values", "styles.xml"),
        os.path.join(flutter, "android", "app", "src", "main", "res",
                     "values-night", "styles.xml"),
    ]

    for target in [home_page, manifest, gradle] + styles:
        if not os.path.isfile(target):
            raise SystemExit("missing file: %s" % target)
    for name in ("console_page.dart", "console_api.dart"):
        if not os.path.isfile(os.path.join(pages, name)):
            raise SystemExit("missing %s in %s" % (name, pages))

    patch_home_page(home_page)
    patch_manifest(manifest)
    for style_path in styles:
        patch_styles(style_path)
    patch_gradle(gradle)
    print("console mobile patch applied")


if __name__ == "__main__":
    main()
