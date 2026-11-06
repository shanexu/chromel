#!/usr/bin/env python3
"""Test isolated GUI Emacs instances: persistence, layout, hints and controls."""
import http.server
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import threading

root = pathlib.Path(__file__).resolve().parent.parent
# Test-only observer for NSApp.run reentry, never loaded by the browser itself.
subprocess.run(["cmake", "-S", str(root), "-B", str(root / "build")], check=True)
subprocess.run(["cmake", "--build", str(root / "build"), "--target", "chromel-pump-probe"], check=True)
host = subprocess.check_output(["python3", str(root / "scripts/prepare-host.py")], text=True).strip()
emacs = str(pathlib.Path(host) / "Contents/MacOS/Emacs")


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
        if self.path == '/hint-target':
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
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


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
        ]
        only = [part for part in os.environ.get("CHROMEL_TEST_ONLY", "").split(",") if part]
        if only:
            tests = [t for t in tests if any(part in t[1] or part in t[0] for part in only)]
        for expected, script in tests:
            route = {'gui-passwords.el': '/passwords', 'gui-features.el': '/features', 'gui-controls.el': '/controls', 'gui-scroll.el': '/scroll', 'gui-hold.el': '/scroll',
                     'gui-scroll-modal.el': '/scroll-modal'}.get(script, '/fixture')
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
                     "-L", str(root), "-l", str(root / "test" / script),
                     # Cocoa reads this at startup; keep it away from Emacs's
                     # file-argument parser.  Avoid crash-recovery modal dialogs
                     # in disposable test processes without changing defaults.
                     "--eval", "(setq command-line-args-left nil)",
                     "-ApplePersistenceIgnoreState", "YES"],
                    env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    status = process.wait(timeout=55)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    status = 124
            print(log.read_text())
            if result.is_file():
                print(result.read_text())
            else:
                print(f"FAIL: GUI process exited ({status}) without a test result")
            if status:
                raise SystemExit(status)
            if script in ("gui-settings.el", "gui-passwords.el", "gui-management.el"):
                assert "Chromel: skipping CefShutdown" not in log.read_text(), "Settings prevented clean CEF shutdown"
            history = json.loads((pathlib.Path(temp) / "profile/history.json").read_text())
            assert any(entry["url"] == test_url for entry in history), "History was not saved"
        print("PASS: Cookie, localStorage and history persist across two Emacs processes")
finally:
    server.shutdown()
    server.server_close()
