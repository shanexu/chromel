#!/usr/bin/env python3
"""Assemble a self-contained CEF runtime bundle without modifying Emacs.app."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

from bundle_privacy import with_bluetooth_usage


def plist(path, name, identifier, **extra):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = dict(CFBundleExecutable=name, CFBundleIdentifier=identifier,
                CFBundleName=name, CFBundlePackageType="APPL",
                CFBundleVersion="1", CFBundleShortVersionString="0.1.0",
                NSHighResolutionCapable=True, LSMinimumSystemVersion="13.0")
    data.update(extra)
    path.write_bytes(plistlib.dumps(data))


def main():
    cef = pathlib.Path(sys.argv[1]).resolve()
    build = pathlib.Path(sys.argv[2]).resolve()
    bundle = build / "ChromelRuntime.app"
    contents = bundle / "Contents"
    frameworks = contents / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    framework = frameworks / "Chromium Embedded Framework.framework"
    # ditto preserves framework symlinks, modes and resource layout.
    subprocess.run(["ditto", str(cef / "Release" / framework.name), str(framework)], check=True)
    # CMake links the smoke host straight into Contents/MacOS; CEF refuses to
    # load a framework that is not inside the running app bundle.
    host = contents / "MacOS" / "ChromelRuntime"
    if not host.is_file():
        raise SystemExit(f"missing {host}; run ./scripts/build.sh")
    plist(contents / "Info.plist", "ChromelRuntime", "org.emacs.chromel.runtime",
          **with_bluetooth_usage({}))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    for suffix in ["", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)"]:
        name = "Chromel Helper" + suffix
        helper = frameworks / (name + ".app")
        executable = helper / "Contents" / "MacOS" / name
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(build / "chromel-helper", executable)
        identifier = "org.emacs.chromel.helper" + ("." + suffix.strip(" ()").lower() if suffix else "")
        plist(helper / "Contents" / "Info.plist", name, identifier, LSUIElement=True)
        (helper / "Contents" / "PkgInfo").write_bytes(b"APPL????")
        subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True)
    # Local ad-hoc signature; distribution/notarization requires an identity.
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(build / "chromel-module.dylib")], check=True)


if __name__ == "__main__":
    main()
