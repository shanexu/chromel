#!/usr/bin/env python3
"""Test isolated GUI Emacs instances: persistence, layout, hints and controls."""
import base64
import http.server
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import threading

root = pathlib.Path(__file__).resolve().parent.parent
build = root / "build"
# A stale chromel.elc shadows the source file (load prefers the compiled one),
# so a run can silently test last week's elisp.  Delete them like CI does.
for stale in root.rglob("*.elc"):
    stale.unlink()
module = build / "chromel-module.dylib"
subprocess.run(["cmake", "-S", str(root), "-B", str(build)], check=True)
# Build everything the GUI processes load, not just the probe: a failed compile
# used to leave the previous dylib in place, and the suite then reported PASS
# while testing stale native code.
try:
    subprocess.run(
        ["cmake", "--build", str(build), "--target", "chromel-module", "chromel-pump-probe", "chromel-smoke"],
        check=True)
except subprocess.CalledProcessError:
    raise SystemExit(
        "FAIL: native build failed; refusing to test a stale chromel-module.dylib")
if not module.is_file():
    raise SystemExit(f"FAIL: {module} is missing after a successful build")
host = subprocess.check_output(["python3", str(root / "scripts/prepare-host.py")], text=True).strip()
emacs = str(pathlib.Path(host) / "Contents/MacOS/Emacs")

# The native host is cheap to run and covers what Emacs-side scripts cannot see
# on their own (renderer, reparenting, teardown).  Run it before spawning 19 GUI
# Emacs processes, with its own throwaway profile.
smoke = build / "ChromelRuntime.app" / "Contents" / "MacOS" / "ChromelRuntime"
if not smoke.is_file():
    raise SystemExit(f"FAIL: {smoke} is missing; run ./scripts/build.sh")
with tempfile.TemporaryDirectory(prefix="chromel-smoke-") as smoke_dir:
    # CEF's test mode insists the profile live under NSTemporaryDirectory, which
    # is what tempfile.gettempdir() returns here.
    result = subprocess.run([str(smoke), "--smoke-test", str(pathlib.Path(smoke_dir) / "profile")],
                            capture_output=True, text=True, timeout=180)
    if result.returncode != 0 or "PASS:" not in result.stdout:
        raise SystemExit(
            "FAIL: native smoke host did not pass\n"
            + (result.stdout or "") + (result.stderr or ""))
    print(next(line for line in result.stdout.splitlines() if line.startswith("PASS:")), flush=True)


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"""<!doctype html><meta charset=utf-8><title>starting</title>
        <style>body {background:#273846;color:white;font:28px sans-serif}</style>
        <h1>CEF in Emacs</h1><input placeholder='Input test'>
        <p><a href='/hint-target'>First link</a></p>
        <p><a href='/second'>Second link</a></p>
        <p><a href='#anchor'>Third link</a></p>
        <p><a href='/fourth'>Fourth link</a></p>
        <a href='/hidden' style='display:none'>Hidden</a>
        <a href='/offscreen' style='position:absolute;top:5000px'>Off screen</a>
        <a href='/covered' style='position:fixed;left:500px;top:0'>Covered</a>
        <div style='position:fixed;left:500px;top:0;width:150px;height:50px;background:black;z-index:10'></div>
        <div id='shadow-host'></div>
        <script>
        document.getElementById('shadow-host').attachShadow({mode:'open'}).innerHTML =
            '<a href="/shadow">Shadow link</a>';
        const restored = localStorage.getItem('chromel-test') === 'saved'
                         && document.cookie.includes('chromel-test=saved');
        localStorage.setItem('chromel-test', 'saved');
        document.cookie = 'chromel-test=saved; Max-Age=3600; Path=/; SameSite=Lax';
        document.title = restored ? 'chromel-emacs-restored' : 'chromel-emacs-ready';
        </script>"""
        content_type = "text/html; charset=utf-8"
        extra_headers = {}
        if self.path.startswith('/download'):
            # A real attachment: CEF hands it to the download handler instead of
            # replacing the page, which is exactly what the test needs.
            body = b"chromel download fixture\n"
            content_type = "application/octet-stream"
            extra_headers["Content-Disposition"] = 'attachment; filename="chromel-fixture.txt"'
        elif self.path.startswith('/again'):
            # A page whose whole top-left corner is a link to the attachment:
            # Chromium only allows a second automatic download after a trusted
            # click, and this gives the test one.
            body = b"""<!doctype html><meta charset=utf-8><title>again-fixture</title>
<style>html,body{margin:0;height:100%}a{position:fixed;left:0;top:0;width:160px;
height:80px;display:block;background:#334;color:#fff;font:16px system-ui}</style>
<a id="again" href="/download?again">download again</a>"""
        elif self.path.startswith('/permission'):
            # Chromium asks before a page may post notifications; the answer
            # ends up in the title so the test can see what the page received.
            body = b"""<!doctype html><meta charset=utf-8><title>permission-fixture</title>
<script>
Notification.requestPermission().then(function (result) {
  document.title = 'perm:' + result + location.search;
});
</script><h1>Permission</h1>"""
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/paste'):
            # A focused text field the size of the viewport, so a synthetic
            # click always lands inside it.
            # The title mirrors the field, so a test can read the value through
            # the browser's title changes instead of evaluating scripts.
            body = (b"<!doctype html><title>value:</title>"
                    b"<input id=i oninput=\"document.title='value:'+this.value\" "
                    b"style=\"position:fixed;left:0;top:0;width:400px;height:200px;"
                    b"font-size:20px\">")
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/blocker'):
            # The page lives on 127.0.0.1; the image it embeds lives on
            # 127.0.0.2, so the blocklist can cancel exactly one of them and the
            # browser still knows how to reach the other.
            body = (f"<!doctype html><title>blocker-fixture</title>"
                    f"<img src=\"http://localhost:{self.server.server_port}/ad.png\" "
                    "onload=\"document.title='ad-loaded'\" "
                    "onerror=\"document.title='ad-blocked'\">").encode()
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/inputs-frame'):
            body = (b"<!doctype html><meta charset=utf-8><title>inputs-child</title>"
                    b"<input id=\"fourth\" value=\"fourth\">")
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/inputs'):
            # Hidden and non-text inputs must not be counted; the iframe is
            # same-origin so the field walk should reach it.
            body = (b"<!doctype html><meta charset=utf-8><title>inputs-fixture</title>"
                    b"<input type=\"hidden\" id=\"hidden\" value=\"x\">"
                    b"<input type=\"checkbox\" id=\"check\">"
                    b"<input id=\"first\" value=\"first\">"
                    b"<textarea id=\"second\">second</textarea>"
                    b"<div id=\"third\" contenteditable=\"true\" style=\"height:40px\">third</div>"
                    b"<iframe id=\"frame\" src=\"/inputs-frame\" style=\"height:80px;width:300px\"></iframe>")
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/cosmetic-frame'):
            body = (b"<!doctype html><title>cosmetic-child</title>"
                    b"<div id=\"banner\" style=\"height:60px\">child banner</div>")
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/cosmetic'):
            # Both the banner and the generic block are hidden by the snapshot
            # the test installs; the child frame proves subframe injection.
            body = (b"<!doctype html><meta charset=utf-8><title>cosmetic-fixture</title>"
                    b"<div id=\"banner\" style=\"height:60px\">banner</div>"
                    b"<div class=\"ad-generic\" style=\"height:40px\">generic</div>"
                    b"<iframe id=\"child\" src=\"/cosmetic-frame\" "
                    b"style=\"width:300px;height:80px\"></iframe>"
                    b"<script>function report(){"
                    b"var main=document.getElementById('banner').offsetHeight===0;"
                    b"var generic=document.querySelector('.ad-generic').offsetHeight===0;"
                    b"var doc=document.getElementById('child').contentDocument;"
                    b"var inner=doc&&doc.getElementById('banner');"
                    b"var sub=!!inner&&inner.offsetHeight===0;"
                    b"document.title='cosmetic:'+main+':'+sub+':'+generic;}"
                    b"setTimeout(report,800);</script>")
            content_type = "text/html; charset=utf-8"
        elif self.path.startswith('/ad.png'):
            body = ONE_PIXEL_PNG
            content_type = "image/png"
        elif self.path == '/hint-target':
            body = b"<!doctype html><meta charset=utf-8><title>hint-target</title><h1>Link followed</h1>"
        elif self.path == '/features':
            body = (root / 'test/features.html').read_text().replace('__OTHER__', f'http://localhost:{self.server.server_port}').encode()
        elif self.path == '/feature-frame':
            body = b"""<!doctype html><style>body{height:2000px;margin:0}</style><p>NeedleFeature in frame</p><script>function report(){parent.postMessage({y:scrollY,height:innerHeight,max:document.scrollingElement.scrollHeight-innerHeight},'*')}addEventListener('scroll',report);addEventListener('load',report);addEventListener('resize',report);</script>"""
        elif self.path.startswith('/feature-target/'):
            body = ('<!doctype html><title>feature-target-' + self.path.rsplit('/',1)[-1] + '</title>Opened').encode()
        elif self.path == '/passwords':
            body = (root / 'test/passwords.html').read_bytes()
        elif self.path == '/controls':
            body = (root / 'test/controls.html').read_bytes()
        elif self.path.startswith('/scroll'):
            other = f"http://localhost:{self.server.server_port}"
            here = f"http://127.0.0.1:{self.server.server_port}"
            if self.path == '/scroll-modal':
                body = (root / 'test/scroll-modal.html').read_bytes()
            elif self.path == '/scroll':
                body = (root / 'test/scroll.html').read_text().replace('__OTHER__', other).encode()
            else:
                body = (root / 'test/scroll-frame.html').read_text()
                body = body.replace('__FRAME_ID__', self.path.split('/')[-1])
                nested = f'<iframe id="nested" name="nested" src="{here}/scroll-frame/nested" style="position:fixed;left:0;top:60px;width:230px;height:150px;border:0"></iframe>' if self.path.endswith('/cross') else ''
                body = body.replace('__NESTED__', nested).encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        for name, header in extra_headers.items():
            self.send_header(name, header)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


# 1x1 transparent PNG: the blocked/unblocked image in the blocker fixture.
ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/fixture"
try:
    with tempfile.TemporaryDirectory(prefix="emacs-chromel-smoke-") as temp:
        # CHROMEL_TEST_ONLY=narrows the run to matching script/title substrings.
        tests = [
            ("chromel-emacs-ready", "gui-smoke.el"),
            ("chromel-emacs-restored", "gui-smoke.el"),
            ("chromel-emacs-restored", "gui-hints.el"),
            ("controls-ready", "gui-controls.el"),
            ("scroll-ready", "gui-scroll.el"),
            ("scroll-ready", "gui-hold.el"),
            ("scroll-modal-ready", "gui-scroll-modal.el"),
            ("chromel-emacs-restored", "gui-escape.el"),
            ("features-ready", "gui-features.el"),
            ("chromel-emacs-restored", "gui-keymap.el"),
            ("chromel-emacs-restored", "gui-pump.el"),
            ("session-seed", "gui-session.el"),
            ("session-restore", "gui-session.el"),
            ("settings-seed", "gui-settings.el"),
            ("settings-restore", "gui-settings.el"),
            ("password-seed", "gui-passwords.el"),
            ("password-restore", "gui-passwords.el"),
            ("management", "gui-management.el"),
            ("crash-fixture", "gui-crash.el"),
            ("chromel-emacs-restored", "gui-download.el"),
            ("chromel-emacs-restored", "gui-permission.el"),
            ("chromel-emacs-restored", "gui-proxy.el"),
            ("paste-fixture", "gui-paste.el"),
            ("blocker-fixture", "gui-blocker.el"),
            ("cosmetic:true:true:true", "gui-cosmetics.el"),
            ("inputs-fixture", "gui-input.el"),
            ("chromel-emacs-restored", "gui-keys.el"),
        ]
        only = [part for part in os.environ.get("CHROMEL_TEST_ONLY", "").split(",") if part]
        if only:
            tests = [t for t in tests if any(part in t[1] or part in t[0] for part in only)]
            # The fixture answers "ready" until some earlier test has written its
            # cookie and localStorage; every "…-restored" expectation therefore
            # depends on the run order.  Filtering could drop that seed and leave
            # a script waiting forever for a title that can never appear.
            if tests and tests[0][0] not in ("chromel-emacs-ready", "session-seed", "settings-seed",
                                             "password-seed", "management"):
                tests.insert(0, ("chromel-emacs-ready", "gui-smoke.el"))
        for expected, script in tests:
            def attempt(expected=expected, script=script):
                """Run one GUI script; returns (status, log text, result text)."""
                route = {'gui-passwords.el': '/passwords', 'gui-features.el': '/features', 'gui-controls.el': '/controls', 'gui-scroll.el': '/scroll', 'gui-hold.el': '/scroll',
                         'gui-scroll-modal.el': '/scroll-modal', 'gui-crash.el': '/crash.html',
                         'gui-paste.el': '/paste', 'gui-blocker.el': '/blocker', 'gui-cosmetics.el': '/cosmetic', 'gui-input.el': '/inputs'}.get(script, '/fixture')
                test_url = url.replace('/fixture', route)
                result = pathlib.Path(temp) / "result"
                result.unlink(missing_ok=True)
                env = dict(os.environ, CHROMEL_TEST_PROFILE=temp + "/profile",
                           CHROMEL_TEST_RESULT=str(result), CHROMEL_CEF_TEST_MODE="1",
                           CHROMEL_TEST_URL=test_url, CHROMEL_TEST_EXPECT_TITLE=expected)
                if script == "gui-settings.el":
                    env["CHROMEL_TEST_SETTINGS_PHASE"] = expected.removeprefix("settings-")
                if script == "gui-passwords.el":
                    env["CHROMEL_TEST_PASSWORD_PHASE"] = expected.removeprefix("password-")
                if script == "gui-session.el":
                    env["CHROMEL_TEST_SESSION_PHASE"] = expected.removeprefix("session-")
                if script == "gui-escape.el":
                    env["CHROMEL_TEST_FULLSCREEN"] = "1"
                log = pathlib.Path(temp) / "emacs.log"
                with log.open("w") as output:
                    process = subprocess.Popen(
                        [emacs, "-Q", "--eval", "(setq native-comp-jit-compilation nil)",
                         "-L", str(root),
                         # Every GUI script runs in the same frame: geometry
                         # assertions and hint labels depend on it.
                         "-l", str(root / "test" / "gui-frame.el"),
                         "-l", str(root / "test" / script),
                         # Cocoa reads this at startup; keep it away from Emacs's
                         # file-argument parser.  Avoid crash-recovery modal dialogs
                         # in disposable test processes without changing defaults.
                         "--eval", "(setq command-line-args-left nil)",
                         "-ApplePersistenceIgnoreState", "YES"],
                        env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        # 90 s was still tight enough that a loaded machine
                        # (parallel builds, another agent) turned a slow test
                        # into a failure; a bogus kill is retried below.
                        status = process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        status = 124
                text = log.read_text()
                result_text = result.read_text() if result.is_file() else ""
                return status, text, result_text, test_url

            # A machine under load can kill a disposable Emacs that was making
            # progress (we have seen -9 and 124 without a single assertion
            # failing).  One retry separates that noise from a real hang; a
            # script that reported FAIL is never retried.
            for attempt_number in (1, 2):
                status, text, result_text, test_url = attempt()
                print(text)
                if result_text:
                    print(result_text)
                # Scripts may append a trace before the verdict; look for the
                # verdict line anywhere in the file.
                verdicts = [line for line in result_text.splitlines()
                            if line.startswith(("PASS:", "FAIL:"))]
                if status == 0 and verdicts and verdicts[-1].startswith("PASS:"):
                    break
                if status == 0:
                    print(f"FAIL: {script} exited without a result")
                elif verdicts:
                    # It reported, then died: that is a real failure, not noise.
                    print(f"FAIL: {script} exited ({status}) after reporting {verdicts[-1]}")
                else:
                    print(f"FAIL: GUI process exited ({status}) without a test result")
                # Retry only a run that produced no verdict at all.  A crash
                # after PASS is indistinguishable from a real teardown bug, and
                # hiding it behind a second run is how a regression gets masked.
                retryable = status != 0 and not verdicts
                if attempt_number == 1 and retryable:
                    print(f"RETRY: {script} died with {status} and no verdict; running it once more")
                    continue
                raise SystemExit(status if status else 1)
            if script in ("gui-settings.el", "gui-passwords.el", "gui-management.el"):
                assert "Chromel: skipping CefShutdown" not in text, "Settings prevented clean CEF shutdown"
            history = json.loads((pathlib.Path(temp) / "profile/history.json").read_text())
            assert any(entry["url"] == test_url for entry in history), "History was not saved"
        print("PASS: Cookie, localStorage and history persist across two Emacs processes")
finally:
    server.shutdown()
    server.server_close()
