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


def patch_gradle(path):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    if 'applicationId "%s"' % APP_ID in src:
        print("build.gradle already patched")
        return
    new = re.sub(r'applicationId\s+"com\.carriez\.flutter_hbb"',
                 'applicationId "%s"' % APP_ID, src, count=1)
    if new == src:
        raise SystemExit("cannot find applicationId in build.gradle")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
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

    for target in (home_page, manifest, gradle):
        if not os.path.isfile(target):
            raise SystemExit("missing file: %s" % target)
    for name in ("console_page.dart", "console_api.dart"):
        if not os.path.isfile(os.path.join(pages, name)):
            raise SystemExit("missing %s in %s" % (name, pages))

    patch_home_page(home_page)
    patch_manifest(manifest)
    patch_gradle(gradle)
    print("console mobile patch applied")


if __name__ == "__main__":
    main()
