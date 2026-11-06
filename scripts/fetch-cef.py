#!/usr/bin/env python3
"""Download the locked CEF distribution, verify it, and print its root path."""
import concurrent.futures
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def host_arch():
    """Return the CEF build matching the *hardware*, not this Python process.

    Under Rosetta, platform.machine() reports x86_64 even on Apple Silicon, and
    downloading macosx64 then produces a dylib that cannot load into an arm64
    Emacs.  hw.optional.arm64 is readable from a translated process and tells
    us what the machine really is.
    """
    probe = subprocess.run(
        ["sysctl", "-n", "hw.optional.arm64"],
        capture_output=True, text=True, check=False)
    if probe.returncode == 0 and probe.stdout.strip() == "1":
        return "macosarm64"
    return {"x86_64": "macosx64", "AMD64": "macosx64"}.get(platform.machine())


def main():
    if sys.platform != "darwin":
        raise SystemExit("This backend requires macOS")
    arch = host_arch()
    if not arch:
        raise SystemExit("Unsupported architecture: %s" % platform.machine())
    if sys.argv[1:] == ["--arch"]:
        print(arch)
        return
    lock = json.loads((ROOT / "cef.lock.json").read_text())
    name = f"cef_binary_{lock['version']}_{arch}_minimal"
    cache = ROOT / ".deps"
    cache.mkdir(exist_ok=True)
    target = cache / name
    if (target / ".verified").is_file():
        print(target)
        return
    archive = cache / (name + ".tar.bz2")
    expected = lock[arch]["sha1"]

    def digest():
        checksum = hashlib.sha1()
        with archive.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(chunk)
        return checksum.hexdigest()

    if not archive.is_file() or digest() != expected:
        url = lock["base_url"] + archive.name
        headers = subprocess.check_output(
            ["curl", "--http1.1", "-fILsS", "--max-time", "60", url], text=True)
        lengths = [int(line.split(":", 1)[1]) for line in headers.splitlines()
                   if line.lower().startswith("content-length:")]
        if not lengths:
            raise SystemExit("CEF server did not provide a download size")
        size = lengths[-1]
        parts = cache / (name + ".parts")
        parts.mkdir(exist_ok=True)
        chunk_size = 2 * 1024 * 1024

        def download(index):
            start = index * chunk_size
            end = min(size, start + chunk_size) - 1
            path = parts / str(index)
            for _ in range(4):
                if path.is_file() and path.stat().st_size == end - start + 1:
                    return path
                subprocess.run([
                    "curl", "--http1.1", "-fLsS", "--connect-timeout", "20",
                    "--max-time", "180", "--range", f"{start}-{end}",
                    url, "-o", str(path)], check=False)
            if path.is_file() and path.stat().st_size == end - start + 1:
                return path
            raise RuntimeError(f"Download failed for part {index}; rerun to resume")

        print(f"Downloading CEF {lock['version']} ({size // 1048576} MiB)", file=sys.stderr)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            paths = list(pool.map(download, range((size + chunk_size - 1) // chunk_size)))
        with archive.open("wb") as output:
            for path in paths:
                output.write(path.read_bytes())
        if digest() != expected:
            raise SystemExit(f"CEF SHA-1 mismatch. Remove {parts} and retry.")
        for path in paths:
            path.unlink()
        parts.rmdir()
    # The archive is pinned by the upstream checksum.  Validate member names
    # before delegating extraction to macOS bsdtar (framework symlinks retained).
    with tarfile.open(archive) as source:
        for member in source:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or path.parts[0] != name:
                raise SystemExit("Unsafe CEF archive path")
    subprocess.run(["tar", "-xjf", str(archive), "-C", str(cache)], check=True)
    (target / ".verified").write_text(expected + "\n")
    print(target)


if __name__ == "__main__":
    main()
