# Chromel 待办

快照：2026-11-06，分支 `p1-hardening`（= `master` = `origin/master`，提交 `9533404`）。

验证基线：`./scripts/build.sh` 0 warning / 0 error，ERT 28/28，`python3 scripts/test-gui.py` 19/19 连续两次全绿。

## 已完成（本轮）

- **P1 崩溃/安全**：`cef.lock.json` 入库；NSException 不越过模块边界；`mainFrame()` 统一守卫；`pumping` 用 RAII；`shutdown()` 不再跑嵌套 AppKit runloop 且两条路径都清理；observer 注销；IPC 空指针检查；`OnBeforeBrowse` 尊重 `userGesture`（特权 `chrome://` 页面必须由用户手势触发，Web Store 交接保留）；settings URL 规则收敛到 native 单一来源；`info()` 不再硬编码 Sandbox；`"javascript"` 有 `chromel-allow-raw-javascript` 开关。
- **P2 交互/性能**：`s` 归还页内搜索、Web Store 移到 `E`（README 与 meow 测试同步）；50 Hz 定时器按需启停（2 秒关停宽限期）；`selected`/layout 变更去重。
- **测试真因**：cmd+click 开新标签改用同窗切换（原先 `pop-to-buffer` 拆 frame，导致 `gui-hints` 只有半屏、标签退化成单字母）；`gui-features` 点击坐标避开视口右侧 16 px 不可命中带；test mode 关闭 Chromium 后台/遮挡节流；合成 Escape 先激活 App 再投递并重试。

## 工作流

- `master` 始终保持绿灯；每项待办开一条 `topic/<短横线-slug>` 分支（例：`topic/devtools-client`），开 PR，CI 绿了再合。CI 的 `pull_request` 触发器就是为这条准备的。
- 只改 Elisp/文档/脚本的 PR：Linux 上的 ERT 就够。
- 改 `native/` 的 PR：描述里附 `./scripts/build.sh` 的零警告证据，并在本机跑 `CHROMEL_TEST_ONLY=<相关脚本> python3 scripts/test-gui.py`，因为 GUI 脚本不进 CI。

## A. 工程护栏（建议优先）

### A1 ✅ 测试可能跑旧 dylib（已修，`scripts/test-gui.py:16-27`）
原先只构建 `chromel-pump-probe`，模块编译失败时套件仍用上一次的 `build/chromel-module.dylib` 跑完并"通过"（本轮实际撞到过）。现在同时构建 `chromel-module`，失败即 `SystemExit`，并断言 dylib 存在。
**已验证**：故意 `#error` → 3 秒退出、rc=1、零个 Emacs 进程启动；恢复后 `CHROMEL_TEST_ONLY=smoke` 全 PASS。

### A2 GUI 脚本依赖环境窗口尺寸
默认 frame 约 560×462 点，`gui-hints`/`gui-features` 的可见元素与坐标都隐含这个尺寸；`gui-controls.el:168`、`gui-hold.el:158`、`gui-scroll-modal.el:122` 已显式 `(set-frame-size nil 1100 750 t)`。
**做法**：所有 GUI 脚本统一在开头设固定尺寸（并在退出时还原）。
**验收**：在两种显示器/缩放设置下结果一致。

### A3 ✅ CI 已拿到绿灯（Linux 跑 ERT，macOS 手动跑原生）
`.github/workflows/ci.yml` 两个作业：
- `elisp`：`ubuntu-latest` + `emacs-nox`，删除任何 `*.elc` 后跑 ERT。**已绿灯**（run 43669553594，提交 `f261ec2`）。ERT 里依赖原生模块的 5 条用 `chromel-test--module-available-p` 跳过，其余 30 条在 Linux 上全跑。
- `native`：macOS，缓存 `.deps`、`build.sh`、拒绝编译警告、校验 `chromel--native-api-version`、带 dylib 再跑 ERT。因为托管 macOS runner 不可用（`macos-14` 报 `configuration 'macos-14-arm64-us-default' is not supported`；`macos-13` 排队到 24 小时被取消），已改为 `if: github.event_name == 'workflow_dispatch'`，只在手动触发时跑。
GUI 脚本需要显示器与会话，未纳入 CI。

### A4 ✅ CEF 下载的架构判断
原先 `platform.machine()` 在 Rosetta 下返回 `x86_64`，会下载 `macosx64` 而让 arm64 Emacs 加载失败。已改为 `host_arch()`：先读 `sysctl -n hw.optional.arm64`，再回退 `platform.machine()` 映射。`python3 scripts/fetch-cef.py --arch` 可直接自检（本机输出 `macosarm64`）。

### A5 ✅ CMake 缺省项
已补 `CMAKE_OSX_DEPLOYMENT_TARGET=13.0` 与默认 `CMAKE_BUILD_TYPE=Release`（均仅在未设置时生效）。裸配置后 `CMakeCache.txt` 确认 `Release` / `13.0`，编译标志含 `-mmacosx-version-min=13.0 -O3 -DNDEBUG`，重编 `chromel_core.mm` 零警告。

### A6 ✅ 原生冒烟接线并可独立运行
根因不是"要嵌进 Emacs"：CEF 的 sandbox 检查要求 framework 位于**运行中的 app bundle** 内，而 `build/chromel-smoke` 在 `build/` 里裸跑，`NSBundle.mainBundle` 就是 `build/`。
做法：CMake 直接把冒烟宿主链接到 `ChromelRuntime.app/Contents/MacOS/ChromelRuntime`（`package.py` 不再拷贝，只校验存在），于是 `NSBundle.mainBundle` 就是那个带 framework 与 5 个 helper 的 bundle。
接线：`scripts/test-gui.py` 在拉起 19 个 GUI Emacs 之前先跑它（独立临时 profile，要求 `rc=0` 且输出含 `PASS:`），构建目标里也加上 `chromel-smoke`，避免用旧二进制跑绿。
**验证**：`build/ChromelRuntime.app/Contents/MacOS/ChromelRuntime --smoke-test "$TMPDIR/x"` 输出 `PASS: renderer, navigation, layout, cross-window reparenting, hide, close, shutdown`；完整套件 `python3 scripts/test-gui.py` → `rc=0`，20 项全绿。

## B. 架构

### B1 `command()` 表驱动化
`native/chromel_core.mm:838-1066`：约 205 行 if/else 链，每个动作各自解析 JSON 并手写类型/范围判断。
**做法**：一张 `{name, arity, parse, run}` 表 + 请求结构体；未知动作仍抛 `Unknown browser action`。
**收益**：新增动作不再复制解析样板；argv 校验可单测。

### B2 ✅ 空队列不再做 JSON 往返
`events()` 在 `requireReady()` 之后直接 `if (queue.count == 0) return "[]";`，空闲 tick 不再走 `NSJSONSerialization`。返回值与序列化空数组完全一致（`gui-*` 的 `--chromel-last` / 事件处理未受影响，ERT 35/35）。

### B3 ✅ DevTools 有了自己的 client
原先 `ShowDevTools(wi, new Client(0), …)`：id 0 会让 `emit()` 直接返回，`pageFor(0)` 也无效，于是 DevTools 里的链接点了没反应。
现在 `DevToolsClient(int owner)`（`native/chromel_core.mm`）：自己维护 `OnAfterCreated`/`OnBeforeClose` 的注册表项，**只**把“用户在 DevTools 里点开的链接”按所属页面回报为 `popup`/`popup-background`，其余事件（title/url/focus）仍然丢弃——它们属于检查器，不属于页面。
**验证**：`./scripts/build.sh` 零警告；ERT 35/35；`CHROMEL_TEST_ONLY=smoke,controls,features` GUI 全绿。手工探针（经 `scripts/launch.sh`）：加载后 `Pages:1 / Browsers:1` → 开 DevTools `Pages:1 / Browsers:2` → 关页面 `Pages:0 / Browsers:0`；同一探针在改动前的 master 上得到完全相同的计数，说明注册表行为未变，改的只是事件归属。

### B4 hints.js 每次 follow 从磁盘读
`chromel.el:838-840` 每次 `insert-file-contents "native/hints.js"`，而 `scroll.js` 是构建期内嵌（`CMakeLists.txt:32-34`）。**做法**：统一由 CMake 生成头文件，Elisp 侧只取字符串。

### B5 ✅ 没有 Elisp↔模块 ABI 握手
`chromel_core.h` 新增 `kChromelApiVersion`（C5 之后为 2）与 `api_version()`，模块导出 `chromel--native-api-version`；`chromel-module-api-version` 与 `chromel--check-module-api` 在 `chromel--ensure-module` 末尾断言，缺函数或数字不符都直接 `user-error` 并提示 `./scripts/build.sh`。ERT 增 2 条（一致、`nil` 与 `99` 两种不符），31/31 通过（C5 升到 2 后为 35/35）。

### B6 testMode 渗进生产路径
`command()`/`click`/`initialize()` 里散落 `testMode` 分支。**做法**：收敛到单一 `isTestMode()` + 一处文档说明，避免将来在正式路径误开。

### B7 全局状态
21 个全局 defvar、单个 1039 行 TU、`pages/browsers/settings*` 都是文件级全局。已有 `Page` 结构，但没有会话对象。**做法**：先把 settings 相关 6 个全局收进一个 `SettingsState`，作为中间步。

### B8 用 frame title 找 NSWindow
`chromel.el:191-206` 的 `chromel--frame-handle` 临时改 frame title、调 `chromel--native-bind` 再改回。**先调研**：Cocoa 的 `(frame-parameter frame 'window-id)` 是否已给出 NSWindow number；能拿到就删掉这个 hack。

## C. 行为与 UX

### C1 ✅ 延迟标签的命令路径有测试兜底
`chromel--command` 先在 raw-JS 开关上做判定、再 `chromel--ensure-browser`，最后才要求 `chromel--id`。新增两条 ERT：`chromel-command-materializes-a-deferred-tab-first`（断言调用顺序是 ensure → native，且 native 收到新建的 id）与 `chromel-command-refuses-a-tab-that-stayed-deferred`（仍 pending 时 `user-error`）。

### C2 ✅ 搜索引擎写死 DuckDuckGo
新增 `defcustom chromel-search-url`（默认 `https://duckduckgo.com/?q=%s`，要求含 `%s`），`chromel--normalize-url` 用 `format` 套用，查询串仍走 `url-hexify-string`。ERT 增加 3 条：默认模板、`%` 转义（`100%25`）、自定义模板生效；29/29 通过。
> 顺带发现：仓库里的 `chromel.elc` 是未跟踪的构建产物，`load` 会优先加载它，改完 `chromel.el` 直接跑 ERT 会测到旧逻辑（本轮先踩了一次）。建议后续在测试脚本里强制 `load` 源文件或先删 `.elc`。

### C3 ✅ 已知限制已写入 README
行为未改（仍由 Emacs 开新标签），但 README「数据和能力边界」明确写出：页面发起的新窗口转成新的 Emacs buffer，`window.opener` 关系不保留，依赖脚本弹窗通信的登录流程可能不兼容。要真正支持需要区分「用户手势链接」与「脚本 window.open」，属于行为改造，不在此轮范围。

### C4 hints 标签依赖可见数量
`gui-hints` 曾因可见链接从 6 降到 2、标签退化成单字母而超时。**做法**：`test/gui-hints.el` 不假设标签长度/数量（按 `hints` 返回的 label 逐个敲），或固定窗口尺寸后断言完整列表。

### C5 ✅ 泵的空闲判定改问 native
`chromel_core.h` 新增 `int browser_count();`（只读 `browsers` + `settingsBrowsers`，**不**经 `requireReady`，CEF 未初始化时返回 0）；模块导出 `chromel--native-browser-count`；Elisp 新增 `chromel--native-has-browsers-p`，`chromel--pump-needed-p` 用它取代原先永不重置的 `chromel--settings-open`（该变量已删除）。`chromel-settings` 改为「先发 settings 命令、再 `chromel--ensure-timer`」，因为窗口是在那条命令里同步创建的。API 版本随之升到 2。ERT 新增 2 条并更新 2 条（无页面/无浏览器时停泵、设置窗口存在时继续泵、模块未加载时不问 native）。

## D. 文档

- ✅ `docs/architecture.md`：分层、外部消息泵、视图嵌入与坐标系、事件/命令、JS 往返、键盘双路径、焦点、生命周期、不变量、扩展点（README 顶部已链入）。
- README 明确：CEF 必须在 app bundle 内（`install-app.py` 的理由）、`C-c w E` 与 `s` 的分工、`chromel-allow-raw-javascript` 的取舍、session/history 文件位置与恢复命令。
- ✅ `CHANGELOG.md`：0.1.0 起按"崩溃与安全 / 交互 / 测试与构建 / 文档"分类。
- ✅ README 已补：CEF 为何必须在 app bundle 内、`chromel-allow-raw-javascript` 的取舍。

## 常用验证

```bash
./scripts/build.sh                       # 0 warning
emacs --batch -L . -L test -l test/chromel-test.el -f ert-run-tests-batch-and-exit
python3 scripts/test-gui.py              # 19 项，约 4-5 分钟，会抢焦点
CHROMEL_TEST_ONLY=smoke,hints python3 scripts/test-gui.py   # 子集
```

## 已知外部问题（不是本项目的 bug）

- **删除已被输入法接管的 frame 会让 Emacs 31.1 abort**：`make-frame` → 等待（哪怕 1 秒）→ `delete-frame`，崩溃于 `-[EmacsView selectedRange]`（经 `handleTSMEvent` 从 IMK 进入），随后 `emacs_abort`。`emacs -Q`、不加载 chromel、不启动 CEF 也能复现（5/5），属于 Emacs/macOS 交互缺陷。项目侧规避：`test/gui-smoke.el` 用 `make-frame-invisible` 代替 `delete-frame`（提交 `136f5e3`）。若将来要覆盖"删除 frame"的清理路径，需要先确认上游修好。
- **GitHub macOS runner 不可用**：`macos-14` 报 `The configuration 'macos-14-arm64-us-default' is not supported`；`macos-13` 被接受但长期 queued 直到 24 小时被取消。CI 的 `elisp` 作业可改 `ubuntu-latest`，`native` 作业保留手动触发。
