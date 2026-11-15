# Content Blocker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 uBOL 的三套标准规则在 Chromel 里做网络层广告/追踪拦截，默认生效，并能一键关掉当前站点。

**Architecture:** `scripts/ubol-to-blocklist.py` 把 uBOL 的 DNR JSON 编译成行式规则文件（第一版只保留域名规则）；`native/blocklist.{h,mm}` 在 CEF 启动后加载成 host 后缀表；`Client` 通过 `CefResourceRequestHandler::OnBeforeResourceLoad`（**IO 线程**）查表并取消请求；Elisp 负责配置、按站点例外与命令。

**Tech Stack:** Objective-C++ / CEF 156 / Emacs Lisp / Python 3（仅构建期）。

**Spec:** `docs/superpowers/specs/2026-11-15-content-blocker-design.md`

## Global Constraints

- 只支持 macOS（CEF Alloy，现状不变）；不引入新依赖，Python 只用标准库。
- `OnBeforeResourceLoad` 跑在 **IO 线程**：查表只读，加载期建好的表用 `std::shared_ptr<const Tables>` 原子换入；计数用 `std::atomic<unsigned long>`；**绝不**在该函数里碰 AppKit / CefFrame / CefBrowser 的 UI 方法。
- 第一版只做域名/发起站点规则，性能门槛 **< 20 µs/请求**。
- `allow` 规则优先于 `block`（同一请求两者都命中时放行）。
- 规则文件缺失或损坏 → 禁用拦截并 `message` 说明，不抛到用户面前、不阻断浏览。
- 列表许可是 GPL-3.0（uBOL）+ CC BY-SA（EasyList/EasyPrivacy），数据入库必须在 `data/blocklist.LICENSE` 注明来源。
- 提交前必须：`./scripts/build.sh` 退出码 0 且 `warning:` 计数为 0；`emacs --batch … ert-run-tests-batch-and-exit` 全绿；删掉 `chromel.elc`。

## Review Focus

1. **规则文件缺失/损坏**：用户把 `chromel-blocklist-file` 指到一个不存在的路径，期望"照常上网 + 一句提示"，不是报错或空白页。→ Task 3 的 `chromel-blocklist-missing-file-reports-an-error`、Task 5 的 `chromel-blocker-apply-survives-a-broken-file`。
2. **`allow` 与 `block` 同时命中同一 host**：期望放行（站点自己声明的例外不能被广告规则盖掉）。→ Task 3 的 `chromel-blocklist-blocks-hosts-and-respects-allow`。
3. **主机名的脏输入**（`Ads.Example.COM:8080`、末尾点、大小写混合）：期望照常匹配。→ Task 3 的 `chromel-blocklist-smells-host-case-and-port`。
4. **资源类型掩码**：只对 `script` 生效的规则不能把 `image` 也拦掉。→ Task 3 的 `chromel-blocklist-honours-resource-types`。
5. **例外的边界**：给 `example.com` 加例外时，`ads.example.net` 的请求不能被顺带放行；`C-u` 升父域遇到 `co.uk` 这类公共后缀必须拒绝。→ Task 5 的两个 toggle 测试。

---

### Task 1: 转换器 v1（域名规则 + 统计 + 测试）

**Files:**
- Modify: `scripts/ubol-to-blocklist.py`
- Test: `test/test_blocklist_converter.py`（新建，`python3 -m unittest` 运行）

**Interfaces:**
- Produces: 命令行 `python3 scripts/ubol-to-blocklist.py <ruleset.json…> -o <out> [--label S]`；输出文件首行 `# chromel-blocklist 1`，之后每行 `action \t types-hex \t flags \t spec`，`spec` 为 `h=<suffix>` 加可选 `i=<suffix>`（`;` 分隔）。
- Produces: `compile_rulesets(paths) -> (lines: list[str], stats: dict)`，供测试直接导入。

- [ ] **Step 1: 写失败的测试**

```python
import importlib.machinery, importlib.util, unittest
loader = importlib.machinery.SourceFileLoader("ubol", "scripts/ubol-to-blocklist.py")
spec = importlib.util.spec_from_loader("ubol", loader)
ubol = importlib.util.module_from_spec(spec); loader.exec_module(ubol)

class ConvertTest(unittest.TestCase):
    def test_host_rule_becomes_one_line(self):
        lines, stats = ubol.compile_rules([{"id": 1, "priority": 10,
            "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example.com^"}}])
        self.assertEqual(lines, ["b\t0\t\th=ads.example.com"])
        self.assertEqual(stats["emitted"], 1)

    def test_path_and_substring_rules_are_dropped_in_v1(self):
        lines, stats = ubol.compile_rules([
            {"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example.com/a.js"}},
            {"id": 2, "action": {"type": "block"}, "condition": {"urlFilter": "/tracker.gif"}}])
        self.assertEqual(lines, [])
        self.assertEqual(stats["dropped_pattern"], 2)

    def test_allow_survives_and_resource_type_becomes_a_mask(self):
        lines, _ = ubol.compile_rules([{"id": 3, "priority": 30,
            "action": {"type": "allow"},
            "condition": {"requestDomains": ["good.example"], "resourceTypes": ["script"]}}])
        self.assertEqual(lines, ["a\t%x\t\th=good.example" % (1 << ubol.RESOURCE_TYPES.index("script"))])
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `python3 -m unittest test.test_blocklist_converter -v`
Expected: ERROR/FAIL，提示 `module 'ubol' has no attribute 'compile_rules'` 或断言不符。

- [ ] **Step 3: 实现 `compile_rules` 并让 `main()` 调它**

把现有 `spec_for` 收窄为"只产出单个 `h=`（可选 `i=`）的规则"，其他 spec 计入 `dropped_pattern`；空 host（全局子串、纯正则）一律丢弃。`main()` 负责读文件/URL、写头注释（含 `# source:` 与统计）与正文。

- [ ] **Step 4: 运行测试，确认通过**

Run: `python3 -m unittest test.test_blocklist_converter -v`
Expected: `OK`（3 个测试）。

- [ ] **Step 5: 提交**

```bash
git add scripts/ubol-to-blocklist.py test/test_blocklist_converter.py
git commit -m "build: compile uBOL rulesets into a host list"
```

---

### Task 2: 仓库内快照与许可说明

**Files:**
- Create: `data/blocklist.txt`, `data/blocklist.LICENSE`, `data/README.md`

**Interfaces:**
- Produces: `data/blocklist.txt`，首行 `# chromel-blocklist 1`，含 `# source:` 行记录 uBOL commit 与三套列表名。

- [ ] **Step 1: 取规则集（GitHub raw 在本机会被重置，用 blobs API）**

```bash
cd /tmp && curl -sS "https://api.github.com/repos/uBlockOrigin/uBOL-home/git/trees/main?recursive=1" -o tree.json
python3 - <<'PY'
import json, base64, urllib.request
tree = json.load(open('/tmp/tree.json'))['tree']
want = {'ublock-filters', 'easylist', 'easyprivacy'}
shas = {t['path'].split('/')[-1][:-5]: t['sha'] for t in tree
        if t['path'].startswith('chromium/rulesets/main/') and t['path'].endswith('.json')
        and t['path'].split('/')[-1][:-5] in want}
for name, sha in shas.items():
    blob = json.load(urllib.request.urlopen(
        f"https://api.github.com/repos/uBlockOrigin/uBOL-home/git/blobs/{sha}"))
    open(f"/tmp/{name}.json", "wb").write(base64.b64decode(blob['content']))
    print(name, blob['sha'][:12])
PY
```

- [ ] **Step 2: 生成快照并核对**

```bash
cd /Users/shane/src/github.com/guidao/chromel
python3 scripts/ubol-to-blocklist.py /tmp/ublock-filters.json /tmp/easylist.json /tmp/easyprivacy.json \
  -o data/blocklist.txt --label "uBOL main @ <上一步打印的三个 sha>"
head -3 data/blocklist.txt; grep -c '^[ba]' data/blocklist.txt; du -h data/blocklist.txt
```
Expected: 行数 > 90000，体积 < 3 MB，头部含 `# chromel-blocklist 1` 与三套列表名。

- [ ] **Step 3: 写许可与再生成说明**

`data/blocklist.LICENSE` 写清：数据来自 uBlockOrigin/uBOL-home（GPL-3.0）与 EasyList/EasyPrivacy（CC BY-SA 3.0），本仓库只做格式转换，未修改规则语义；附源 URL 与生成日期。`data/README.md` 写"为什么需要快照""怎么重新生成"（复制 Step 1/2 的命令）。

- [ ] **Step 4: 提交**

```bash
git add data/blocklist.txt data/blocklist.LICENSE data/README.md
git commit -m "data: ship a pinned uBOL snapshot"
```

---

### Task 3: 原生匹配器与模块入口（ERT 驱动）

**Files:**
- Create: `native/blocklist.h`, `native/blocklist.mm`
- Modify: `native/module.mm`, `CMakeLists.txt`, `test/chromel-test.el`

**Interfaces:**
- Produces（`namespace chromel`，`native/blocklist.h`）：

```cpp
void load_blocklist(const std::string& path);          // UI 线程；失败抛 std::runtime_error
bool blocklist_loaded();
std::string blocklist_summary();                       // "rules=97598 blocked=0"
bool blocklist_blocks(const std::string& url, int resource_type, const std::string& initiator);
void set_blocklist_exceptions(const std::string& newline_separated);   // UI 线程
```
- Produces（模块函数）：`chromel--native-blocklist-load (path)`、`chromel--native-blocklist-set-exceptions (text)`、`chromel--native-blocklist-info ()`、`chromel--native-blocklist-blocks (url type initiator)`（返回 `t`/`nil`，供测试与将来的"为什么拦"查询）。

- [ ] **Step 1: 写失败的 ERT**

在 `test/chromel-test.el` 末尾追加（沿用现有 `chromel-test--module-available-p` 守卫）：

```elisp
(ert-deftest chromel-blocklist-blocks-hosts-and-respects-allow ()
  (skip-unless (chromel-test--module-available-p))
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# chromel-blocklist 1\n"
                    "b\t0\t\th=ads.example.com\n"
                    "a\t0\t\th=safe.ads.example.com\n"))
          (chromel--native-blocklist-load file)
          (should (chromel--native-blocklist-blocks "http://ads.example.com/x.js" 3 ""))
          (should-not (chromel--native-blocklist-blocks "http://safe.ads.example.com/x.js" 3 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-smells-host-case-and-port ()
  (skip-unless (chromel-test--module-available-p))
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn (with-temp-file file (insert "b\t0\t\th=ads.example.com\n"))
               (chromel--native-blocklist-load file)
               (should (chromel--native-blocklist-blocks "http://Ads.Example.COM:8080/a" 4 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-honours-resource-types ()
  (skip-unless (chromel-test--module-available-p))
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn (with-temp-file file (insert (format "b\t%x\t\th=ads.example.com\n" (ash 1 3))))
               (chromel--native-blocklist-load file)
               (should (chromel--native-blocklist-blocks "http://ads.example.com/a.js" 3 ""))
               (should-not (chromel--native-blocklist-blocks "http://ads.example.com/a.png" 4 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-missing-file-reports-an-error ()
  (skip-unless (chromel-test--module-available-p))
  (should-error (chromel--native-blocklist-load "/nonexistent/blocklist.txt")))
```

- [ ] **Step 2: 运行，确认失败**

Run: `rm -f chromel.elc && emacs --batch -L . -L test -l test/chromel-test.el --eval '(ert-run-tests-batch-and-exit "chromel-blocklist")'`
Expected: 4 个失败，`void-function chromel--native-blocklist-load`。

- [ ] **Step 3: 实现 `native/blocklist.{h,mm}`**

`Rule { unsigned types; bool allow; std::string initiator; }`；`struct Tables { std::unordered_map<std::string, std::vector<Rule>> host; size_t rules; }`；`std::shared_ptr<const Tables> tables`、`std::atomic<unsigned long> blocked{0}`。
解析：跳过 `#` 行，按 `\t` 切 4 段；`spec` 里取 `h=`（必需）与 `i=`（可选），其余标记整行跳过并计数。
匹配：从 URL 取 host（跳过 `://`、userinfo、端口，转小写，去掉末尾点）；对每个后缀候选（`a.b.c` → `a.b.c`,`b.c`,`c`）遍历规则；`types` 为 0 或含该位；`initiator` 非空时要求 initiator host 后缀匹配；**先扫 allow**，命中即返回 false；再扫 block，命中 `++blocked` 并返回 true。
`set_blocklist_exceptions` 用换行分隔的 host 后缀建一张独立表，匹配 initiator host 时直接返回 false（例外优先）。
`blocklist_summary()` 返回 `"rules=%zu blocked=%lu"`；`blocklist_blocks` 在未加载时返回 false。

- [ ] **Step 4: 接进 `native/module.mm` 与 `CMakeLists.txt`**

`enum Op` 增加 `BlocklistLoad`、`BlocklistSetExceptions`、`BlocklistInfo`、`BlocklistBlocks`；参数预取行加入 `BlocklistLoad`/`BlocklistSetExceptions`（`first = string(0)`）与 `BlocklistBlocks`（`first = string(0); numbers[0] = integer(1); second = string(2)`）；四个 `case` 分别调 `load_blocklist`（`std::runtime_error` 由外层 catch 变成 Lisp `error`）、`set_blocklist_exceptions`、`make_string(blocklist_summary())`、`blocklist_blocks(first, numbers[0], second) ? t : nil`；入口表加 `{"blocklist-load", 1, …}`、`{"blocklist-set-exceptions", 1, …}`、`{"blocklist-info", 0, …}`、`{"blocklist-blocks", 3, …}`。`CMakeLists.txt` 的 `add_library(chromel_core STATIC …)` 追加 `native/blocklist.mm`。

- [ ] **Step 5: 构建并跑测试**

Run: `./scripts/build.sh && rm -f chromel.elc && emacs --batch -L . -L test -l test/chromel-test.el --eval '(ert-run-tests-batch-and-exit "chromel-blocklist")'`
Expected: 构建 0 warning；4 个测试 PASS。

- [ ] **Step 6: 提交**

```bash
git add native/blocklist.h native/blocklist.mm native/module.mm CMakeLists.txt test/chromel-test.el
git commit -m "native: match requests against a host blocklist"
```

---

### Task 4: 接入请求链（IO 线程）与计数

**Files:**
- Modify: `native/chromel_core.mm`（`Client` 增加 `GetResourceRequestHandler` 与新的 handler 类）

**Interfaces:**
- Consumes: `chromel::blocklist_loaded()`、`chromel::blocklist_blocks(url, resource_type, initiator)`。
- Produces: `Client::GetResourceRequestHandler(...)` 在列表已加载时返回 `new BlockRequestHandler`；`info()` 输出多一行 `Blocklist: <blocklist_summary()>`。

- [ ] **Step 1: 实现 handler 并接入**

在匿名 namespace 里加：

```cpp
class BlockRequestHandler final : public CefResourceRequestHandler {
 public:
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback>) override {
    if (!request) return RV_CONTINUE;
    const std::string url = request->GetURL().ToString();
    const std::string initiator = request->GetFirstPartyForCookies().ToString();
    if (chromel::blocklist_blocks(url, static_cast<int>(request->GetResourceType()), initiator))
      return RV_CANCEL;
    return RV_CONTINUE;
  }
  IMPLEMENT_REFCOUNTING(BlockRequestHandler);
};
```
`Client` 里加 `CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool,
const CefString&, bool&) override { return chromel::blocklist_loaded() ? new BlockRequestHandler : nullptr; }`；
`info()` 的返回值里加一行 `"Blocklist: " + chromel::blocklist_summary()`。

- [ ] **Step 2: 构建并确认零警告**

Run: `./scripts/build.sh 2>&1 | grep -c "warning:"`
Expected: `0`，且 `build/chromel-module.dylib` 时间戳更新。

- [ ] **Step 3: 量出每请求开销（性能门槛 < 20 µs）**

在 `native/smoke.mm` 里加一个开关：当参数为 `--blocklist-bench <file> <n>` 时，加载该规则文件，用 `n` 条合成 URL（`http://ads.example.com/<i>/x.js`）循环调用 `chromel::blocklist_blocks`，打印 `mean=%.2f us`，然后退出。

Run: `./scripts/build.sh && build/ChromelRuntime.app/Contents/MacOS/ChromelRuntime --blocklist-bench data/blocklist.txt 20000`
Expected: `mean=` 数值 **< 20**，且 `Pages: 0` 之后正常退出（不启动浏览器）。

- [ ] **Step 4: 提交**

```bash
git add native/chromel_core.mm native/smoke.mm
git commit -m "native: cancel blocked requests before they are loaded"
```

---

### Task 5: Elisp 配置、按站点例外与命令

**Files:**
- Modify: `chromel.el`, `test/chromel-test.el`

**Interfaces:**
- Consumes: `chromel--native-blocklist-load`、`chromel--native-blocklist-set-exceptions`、`chromel--native-blocklist-info`。
- Produces: `chromel-blocklist-file`（defcustom）、`chromel-blocker-toggle-site (&optional arg)`、`chromel-blocker-status ()`、`chromel--blocker-apply ()`；例外文件 `blocker.json` 在 `chromel-data-directory`。

- [ ] **Step 1: 写失败的 ERT**

```elisp
(ert-deftest chromel-blocker-toggle-site-adds-and-removes-exact-host ()
  (let ((chromel--blocker-exceptions nil))
    (cl-letf (((symbol-function 'chromel--blocker-page-host) (lambda () "www.example.com"))
              ((symbol-function 'chromel--blocker-save-exceptions) #'ignore)
              ((symbol-function 'chromel--blocker-apply) #'ignore))
      (chromel-blocker-toggle-site)
      (should (equal chromel--blocker-exceptions '("www.example.com")))
      (chromel-blocker-toggle-site)
      (should-not chromel--blocker-exceptions))))

(ert-deftest chromel-blocker-toggle-site-refuses-public-suffix-parent ()
  (let ((chromel--blocker-exceptions nil))
    (cl-letf (((symbol-function 'chromel--blocker-page-host) (lambda () "www.example.co.uk"))
              ((symbol-function 'chromel--blocker-save-exceptions) #'ignore)
              ((symbol-function 'chromel--blocker-apply) #'ignore))
      (should-error (chromel-blocker-toggle-site '(4)))
      (should-not chromel--blocker-exceptions))))

(ert-deftest chromel-blocker-exceptions-round-trip ()
  (let* ((chromel-data-directory (make-temp-file "chromel-data" t))
         (chromel--blocker-exceptions '("example.com" "news.example.org")))
    (unwind-protect
        (progn (chromel--blocker-save-exceptions)
               (setq chromel--blocker-exceptions nil)
               (chromel--blocker-load-exceptions)
               (should (equal chromel--blocker-exceptions '("example.com" "news.example.org"))))
      (delete-directory chromel-data-directory t))))

(ert-deftest chromel-blocker-apply-survives-a-broken-file ()
  (skip-unless (chromel-test--module-available-p))
  (let ((chromel-blocklist-file "/nonexistent/blocklist.txt")
        (chromel--blocker-exceptions nil))
    (cl-letf (((symbol-function 'message) #'ignore))
      (should-not (chromel--blocker-apply)))))
```

- [ ] **Step 2: 运行，确认失败**

Run: `rm -f chromel.elc && emacs --batch -L . -L test -l test/chromel-test.el --eval '(ert-run-tests-batch-and-exit "chromel-blocker")'`
Expected: 4 个失败，`void-function chromel-blocker-toggle-site`。

- [ ] **Step 3: 实现 Elisp**

- `(defcustom chromel-blocklist-file (expand-file-name "data/blocklist.txt" chromel--directory) …)`。
- `(defvar chromel--blocker-exceptions nil)`、`(defvar chromel--blocker-public-suffixes '("co.uk" "com.cn" "com.au" "co.jp" "github.io" …))`。
- `chromel--blocker-page-host`：当前 buffer 的 `chromel--url` 取 host（无则 `user-error "This buffer has no page"`）。
- `chromel--blocker-apply`：文件不可读 → `message "Chromel: no blocklist at %s"` 并返回 nil；否则 `(chromel--native-blocklist-load file)` 后 `(chromel--native-blocklist-set-exceptions (mapconcat #'identity chromel--blocker-exceptions "\n"))`，返回 t，出错时 `message` 并返回 nil。
- `chromel--blocker-load-exceptions` / `chromel--blocker-save-exceptions`：`blocker.json`，原子写（临时文件 + `rename-file`，模式 600），与 session 写法一致。
- `chromel-blocker-toggle-site (&optional arg)`：exact host；`arg`（`C-u`）时取末两段，若它是 `chromel--blocker-public-suffixes` 里的项或只有一段则 `user-error`；切换后保存、`chromel--blocker-apply`、`message`。
- `chromel-blocker-status`：`message "Chromel blocker: %s; site %s"`，数据来自 `chromel--native-blocklist-info` 与当前 host 是否在例外里。
- `chromel--start` 里在 `(chromel--apply-proxy-pac)` 之后加 `(chromel--blocker-apply)`；`chromel--ensure-module` 之后同样调用一次（模块重新加载时恢复）。

- [ ] **Step 4: 运行，确认通过**

Run: `rm -f chromel.elc && emacs --batch -L . -L test -l test/chromel-test.el -f ert-run-tests-batch-and-exit`
Expected: 全绿（新增 4 条 + 原有 44 条）。

- [ ] **Step 5: 提交**

```bash
git add chromel.el test/chromel-test.el
git commit -m "elisp: load the blocklist and let a site opt out"
```

---

### Task 6: GUI 回归（真实请求被取消）

**Files:**
- Create: `test/gui-blocker.el`
- Modify: `scripts/test-gui.py`（fixture 路由 + 测试表）

**Interfaces:**
- Consumes: `chromel--native-blocklist-load`（测试里直接写规则文件并加载）。
- Produces: fixture 路由 `/blocker`：返回
  `<title>blocker-fixture</title><img src="http://127.0.0.2:PORT/ad.png" onload="document.title='ad-loaded'" onerror="document.title='ad-blocked'">`，
  其中 `PORT` 由 fixture 自己的端口填入。

- [ ] **Step 1: 写失败的测试**

`test/gui-blocker.el`：把 `(expand-file-name "blocklist.txt" (make-temp-file "chromel-bl" t))` 写成 `b\t0\t\th=127.0.0.2`，`(chromel--native-blocklist-load file)`，打开 origin `"/blocker"`，等标题 `ad-blocked`；然后 `(setq chromel--blocker-exceptions '("127.0.0.1"))` + `(chromel--blocker-apply)` + `chromel-reload`，等标题 `ad-loaded`；最后按既有协议写 `CHROMEL_TEST_RESULT` 并 `(kill-emacs 0)`。

- [ ] **Step 2: 运行，确认失败**

Run: `CHROMEL_TEST_ONLY=smoke,blocker python3 scripts/test-gui.py`
Expected: 失败于"路由不存在"或标题超时（`blocker-fixture` 打不开）。

- [ ] **Step 3: 加 fixture 路由与表项**

`scripts/test-gui.py` 的 `do_GET` 里加 `elif self.path.startswith('/blocker'):` 分支，正文用 `self.server.server_port` 填端口，`Content-Type: text/html`；`tests` 表加 `("blocker-fixture", "gui-blocker.el")`；路由映射加 `'gui-blocker.el': '/blocker'`。

- [ ] **Step 4: 运行，确认通过**

Run: `CHROMEL_TEST_ONLY=smoke,blocker python3 scripts/test-gui.py`
Expected: 2 项 PASS。

- [ ] **Step 5: 提交**

```bash
git add test/gui-blocker.el scripts/test-gui.py
git commit -m "test: prove a blocked request never leaves the browser"
```

---

### Task 7: 文档与全套验证

**Files:**
- Modify: `README.md`, `docs/architecture.md`, `CHANGELOG.md`, `TODO.md`

- [ ] **Step 1: 写文档**

`README.md` 新增「## 内容拦截（广告/追踪）」：默认名单与快照位置、`chromel-blocklist-file`、`M-x chromel-blocker-toggle-site`（`C-u` 升父域）、`M-x chromel-blocker-status`、规则更新步骤（指向 `data/README.md`）、已知不精确（忽略第三方标记、只有域名规则）。`docs/architecture.md` 新增一节「内容拦截：请求链上的域名表」，说明 IO 线程、`GetResourceRequestHandler`、allow 优先、例外用 initiator 近似、计数位置；测试计数更新为新数字。`CHANGELOG.md` 加一条；`TODO.md` 新增对应条目并标 ✅，基线改为新的 ERT/GUI 数字。

- [ ] **Step 2: 全套验证**

Run: `./scripts/build.sh && rm -f chromel.elc && emacs --batch -L . -L test -l test/chromel-test.el -f ert-run-tests-batch-and-exit && python3 -m unittest test.test_blocklist_converter -v && python3 scripts/test-gui.py`
Expected: 构建 0 warning；ERT 全绿；unittest `OK`；GUI 25 项 PASS、rc=0。

- [ ] **Step 3: 提交**

```bash
git add README.md docs/architecture.md CHANGELOG.md TODO.md
git commit -m "docs: describe the content blocker"
```
