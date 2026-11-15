# Chromel 待办

快照：2026-11-15，分支 `topic/renderer-crash`（基于 `master` `0d078ed`）。

验证基线：`./scripts/build.sh` 0 warning / 0 error，ERT 43/43，`python3 scripts/test-gui.py` 23/23 全绿。

## 已完成（本轮）

- **P1 崩溃/安全**：`cef.lock.json` 入库；NSException 不越过模块边界；`mainFrame()` 统一守卫；`pumping` 用 RAII；`shutdown()` 不再跑嵌套 AppKit runloop 且两条路径都清理；observer 注销；IPC 空指针检查；`OnBeforeBrowse` 尊重 `userGesture`（特权 `chrome://` 页面必须由用户手势触发，Web Store 交接保留）；settings URL 规则收敛到 native 单一来源；`info()` 不再硬编码 Sandbox；`"javascript"` 有 `chromel-allow-raw-javascript` 开关。
- **P2 交互/性能**：`s` 归还页内搜索、Web Store 移到 `E`（README 与 meow 测试同步）；定时器按需启停（2 秒关停宽限期，后来进一步做成按 CEF 请求变频，见 B9）；`selected`/layout 变更去重。
- **测试稳定性**：`gui-hold` 稳态速度改用最小二乘斜率（逐帧 dy/dt 会被单个迟到帧带偏，实测斜率 899.9–900.3 px/s 而逐帧 691–1164）；单测超时 55 s → 90 s。
- **测试真因**：cmd+click 开新标签改用同窗切换（原先 `pop-to-buffer` 拆 frame，导致 `gui-hints` 只有半屏、标签退化成单字母）；`gui-features` 点击坐标避开视口右侧 16 px 不可命中带；test mode 关闭 Chromium 后台/遮挡节流；合成 Escape 先激活 App 再投递并重试。

## 工作流

- `master` 始终保持绿灯；每项待办开一条 `topic/<短横线-slug>` 分支（例：`topic/devtools-client`），开 PR，CI 绿了再合。CI 的 `pull_request` 触发器就是为这条准备的。
- 只改 Elisp/文档/脚本的 PR：Linux 上的 ERT 就够。
- 改 `native/` 的 PR：描述里附 `./scripts/build.sh` 的零警告证据，并在本机跑 `CHROMEL_TEST_ONLY=<相关脚本> python3 scripts/test-gui.py`，因为 GUI 脚本不进 CI。

## A. 工程护栏（建议优先）

### A1 ✅ 测试可能跑旧 dylib（已修，`scripts/test-gui.py:16-27`）
原先只构建 `chromel-pump-probe`，模块编译失败时套件仍用上一次的 `build/chromel-module.dylib` 跑完并"通过"（本轮实际撞到过）。现在同时构建 `chromel-module`，失败即 `SystemExit`，并断言 dylib 存在。
**已验证**：故意 `#error` → 3 秒退出、rc=1、零个 Emacs 进程启动；恢复后 `CHROMEL_TEST_ONLY=smoke` 全 PASS。

### A2 ✅ 所有 GUI 脚本跑在同一个固定尺寸的 frame 里
这些脚本的几何断言隐含一个 frame 尺寸，而默认值随显示器和字体变化（`gui-hints` 曾在只有 224px 高时把 6 个链接砍到 2 个）。
新增 `test/gui-frame.el` 只做一件事：`(set-frame-size nil 1100 750 t)`；`scripts/test-gui.py` 在加载每个脚本前先 `-l test/gui-frame.el`。原先 4 个脚本里的同尺寸调用保留（幂等，也方便单文件手跑）。
**验证**：完整套件在新尺寸下 20/20 PASS —— 这一轮同时证明了 C4：旧的硬编码 `a a s` 在 1100×750 下必然失败（可见链接变多、标签变长）。

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

### A7 ✅ CEF 的 bundle 不再靠 `invocation-directory` 猜
`chromel--start` 原本用 `(expand-file-name "../.." invocation-directory)` 反推宿主 bundle，再用"framework 是否在里面"做校验。实测（相对路径启动 `build/EmacsChromel.app/Contents/MacOS/Emacs`）：`invocation-directory` 返回 `/Users/shane/build/EmacsChromel.app/Contents/MacOS/` —— 少了 `src/github.com/guidao/chromel/` 一段，检测失败、回落到 `ChromelRuntime.app`，最后被 CEF 的 sandbox 检查拒绝（`CEF sandbox requires its framework inside the running app bundle`）。软链、`open`、从 GUI 启动都可能触发同类问题。
**做法**：native 新增 `bundle_path()`（`NSBundle.mainBundle.bundlePath`）与 `chromel--native-bundle-path`，`chromel--start` 直接采信 AppKit；旧模块没有该函数时退回 `file-truename` 版本。模块 API 升到 **3**。
**验证**：同一探针（相对路径启动 + `(chromel "https://example.org/")` + `chromel--sync` + `inspect`）从 `rc=1 / "CEF sandbox requires…"` 变为 `rc=0`，inspect 正常返回几何与 `window`；构建 0 警告；ERT 35/35；`CHROMEL_TEST_ONLY=smoke,controls` 全 PASS。

## B. 架构

### B1 ✅ `command()` 表驱动化
**已完成（`command()` 表驱动，PR #7）**：动作移入 `browserActions()` / `settingsActions()` 两张 `std::map`，派发只剩「查找 + 调用」；设置窗口走 id 0 的另一张表。校验逻辑逐条原样搬运，没有顺手改行为。文件从 1039 行涨到 1311 行——**行数变多是刻意的取舍**：每个条目重复一遍 lambda 签名，换来"动作名即代码名"和"派发不依赖分支顺序"。

原始问题：`native/chromel_core.mm` 里约 205 行 if/else 链，每个动作各自解析 JSON 并手写类型/范围判断。
**做法**：一张 `{name, arity, parse, run}` 表 + 请求结构体；未知动作仍抛 `Unknown browser action`。
**收益**：新增动作不再复制解析样板；argv 校验可单测。

### B9 ✅ 泵的调度（20 ms 常开 → 按 CEF 的请求变频）
**问题（实测）**：加载 chromel 但不打开页面时 CPU 是 0.0%，打开一个 idle 标签页后是 **11.4%**（`build/EmacsChromel.app` + `-Q`，单页 `example.org`，idle 10 秒，`top -pid` 采样）。原因是 Elisp 固定 50 Hz 调 `chromel--native-pump`（`CefDoMessageLoopWork`），而 `App::OnScheduleMessagePumpWork` 是**空实现**——CEF 的调度协议被绕过，改成了猜频率。

**做法**：
- `OnScheduleMessagePumpWork(delayMs)` 只写一个 `std::atomic<bool> pumpPending`（该回调可能在任意线程，绝不碰 Lisp/Cocoa/CEF）；`pump()` 在 `CefDoMessageLoopWork` **之前**清零，避免把泵里重新排的请求丢掉。
- native 新增 `pump_pending()`（`chromel--native-pump-pending`）。它不只看 CEF 的标记，还把两件 CEF 不会替我们排程的事算进来：任一页面有活跃的 `scrollFrame`（JS 滚动是渲染进程自己的时钟，不做这个会在 250 ms 一档里跳帧、松键后还继续漂），以及存在设置窗口。
- Elisp 从"固定 50 Hz"改成"按需变频"：CEF 有活 → 20 ms；连续 10 次没有活（约 200 ms）→ 250 ms 只排事件队列。改频时**不立刻补一帧**（`run-at-time delay delay`），冷启动才允许立即触发。
- 保留原有的空闲宽限期与 `chromel-resume` 语义。

**结果**：idle CPU **11.4% → 1.3%**（约 9 倍），内存不变。

**踩过的坑（都写进代码注释）**：
1. 一开始用"一次性定时器自我续链"，而 `chromel--eval`/`chromel--find-run` 忙等时**直接调用** `chromel--tick`，每次手动 tick 都会多留一个定时器 → 定时器风暴。改成重复定时器 + 仅在频率变化时重建。
2. 频率跟着 `pumpPending` 每 tick 翻转 → 定时器反复重建、每次重建都立刻补一帧 → `gui-hold` 实测速度从"稳定 833 px/s"变成 555–1319 px/s 的抖动。加 10 次静默的滞回 + 改频不补帧后恢复到 4/4 通过。
3. 也试过在 `OnScheduleMessagePumpWork` 里 `dispatch_async` 直接泵（CEF 文档推荐的做法），但那样帧会成对到达，测量同样抖动；已回退，注释说明原因。

**验证**：ERT 35/35；`CHROMEL_TEST_ONLY=smoke,hold` 4/4；完整套件在本次会话里既有 20/20 也有 `gui-hold` 抖动失败——**同一时段 `master` 也一样抖动**（见已知问题），所以不是这刀引入的。

### B2 ✅ 空队列不再做 JSON 往返
`events()` 在 `requireReady()` 之后直接 `if (queue.count == 0) return "[]";`，空闲 tick 不再走 `NSJSONSerialization`。返回值与序列化空数组完全一致（`gui-*` 的 `--chromel-last` / 事件处理未受影响，ERT 35/35）。

### B3 ✅ DevTools 有了自己的 client
原先 `ShowDevTools(wi, new Client(0), …)`：id 0 会让 `emit()` 直接返回，`pageFor(0)` 也无效，于是 DevTools 里的链接点了没反应。
现在 `DevToolsClient(int owner)`（`native/chromel_core.mm`）：自己维护 `OnAfterCreated`/`OnBeforeClose` 的注册表项，**只**把“用户在 DevTools 里点开的链接”按所属页面回报为 `popup`/`popup-background`，其余事件（title/url/focus）仍然丢弃——它们属于检查器，不属于页面。
**验证**：`./scripts/build.sh` 零警告；ERT 35/35；`CHROMEL_TEST_ONLY=smoke,controls,features` GUI 全绿。手工探针（经 `scripts/launch.sh`）：加载后 `Pages:1 / Browsers:1` → 开 DevTools `Pages:1 / Browsers:2` → 关页面 `Pages:0 / Browsers:0`；同一探针在改动前的 master 上得到完全相同的计数，说明注册表行为未变，改的只是事件归属。

### B4 ✅ hints.js 构建期内嵌
原来 `chromel--hint-script` 每次 follow 都 `insert-file-contents "native/hints.js"`，与 `scroll.js` 的构建期内嵌（`CMakeLists.txt` 生成 `chromel_scripts.h`）不一致。
现在 CMake 同时读取 `native/hints.js` → `kChromelHintsSource`，`chromel_core` 导出 `hints_script()`，模块提供 `chromel--native-hints-script`；Elisp 侧 `chromel--hints-source` 缓存一次即可，兜底才读文件（Linux/无模块的 ERT 仍能跑）。
好处：运行时不再依赖源码树里的 `.js`，也不会出现"Elisp 注入了比 dylib 新的脚本"。
**验证**：构建 0 警告；`module=9610 file=9610 equal=t`；ERT 35/35；`CHROMEL_TEST_ONLY=smoke,hints` PASS。

### B5 ✅ 没有 Elisp↔模块 ABI 握手
`chromel_core.h` 新增 `kChromelApiVersion`（A7 之后为 3）与 `api_version()`，模块导出 `chromel--native-api-version`；`chromel-module-api-version` 与 `chromel--check-module-api` 在 `chromel--ensure-module` 末尾断言，缺函数或数字不符都直接 `user-error` 并提示 `./scripts/build.sh`。ERT 增 2 条（一致、`nil` 与 `99` 两种不符），31/31 通过（C5 升到 2 后为 35/35）。

### B6 ✅ 把 testMode 拆成三个有名字的开关
原先一个 `testMode` 同时表达三件事：我是测试进程 / 别打扰用户桌面 / 别碰真 Keychain。读代码的人无法判断某处 `if (!testMode)` 到底是哪个意思，生产里误设环境变量就会得到"设置窗口永不显示"这种真 bug。
现在是 `struct TestSwitches { enabled, quietDesktop, hermetic }`：`CHROMEL_CEF_TEST_MODE=1` 决定 `enabled`，`CHROMEL_CEF_TEST_QUIET` / `CHROMEL_CEF_TEST_HERMETIC` 各自覆盖，默认都跟随 MODE（19 个 GUI 脚本零改动）。`test-*` 动作统一走 `requireTestSwitches()`，生产进程报 `Unknown browser action: <name>` 而不是静默跳过；`info()` 打印三个开关。
验证：完整套件 20/20 PASS（`gui-escape` 走 `test-key`、`gui-settings/passwords/management` 走 `quietDesktop`、`gui-pump` 走计数）。

### B6-old 旧描述（已完成，留档）

### B7 全局状态（进行中：四刀已落地）
21 个全局 defvar、单个 TU、`pages/browsers/settings*` 都是文件级全局。已有 `Page` 结构，但没有会话对象。

**已做（第一刀）**：`Page` 与两张 id→对象表搬进 `native/page.h` / `native/page.mm`，连同 `pageFor`、`ownsFocus`、`stopScroll`、`scrollPage`、`unfocus` 五个按 page 操作的助手。
**已做（第二刀）**：`create` / `layout` / `hide` 与 `windows`、`windowFor` 也搬进 `page.mm`。两个遗留依赖各有解：
- `create()` 原本直接 `new Client(...)`，而 `Client` 是 core 匿名 namespace 里的私有类型。改成 `page.h` 声明 `CefRefPtr<CefClient> makePageClient(int id);`，由 core 在会话作用域实现 `return new Client(id);` —— `page.mm` 只要一个 `CefClient`，不需要知道实现。
- `layout()`/`hide()` 需要"主线程 + 已初始化 + 未关停"的检查。core 里原本是匿名 namespace 的 `requireReady()`，现拆出外部链接的 `requireBackendReady()`（`page.h` 声明），core 的 `requireReady()` 变成一行转发，50 多个调用点不动，错误文案与状态读取只有一份。

`chromel_core.mm` 1311 → 1240 → **1186** 行，`page.mm` 58 → **153** 行。

**已做（第三刀）**：管理窗口整体搬进 `native/settings.h` / `native/settings.mm`（267 行）—— 八个 `settings*` 全局、`SettingsClient`/`SettingsViewDelegate`/`SettingsWindowDelegate`/`SettingsTestObserver`、URL 策略（`loweredAuthority`/`isPrivilegedChromeURL`/`isSettingsURL`）、`openSettings`/`closeSettings`。core 1186 → **992** 行，只留 CEF 回调与编排。

对外只暴露语义，不暴露状态：`makeSettingsClient()`（`App::GetDefaultClient` 用）、`settingsWindowOpen()`/`settingsBrowserCount()`（泵、`info()`、`browser_count()`）、`inspectSettings()`（`inspect(0)`）、`resetSettingsState()`（`shutdown()` 两条路径都调）、以及三个测试钩子 `showSettingsWindow()`/`closeSettingsWindow()`/`runSettingsScript()`。core 反向提供两个谓词给 settings：`quietDesktopMode()`、`testSwitchesEnabled()` —— 测试开关仍只有一份定义。

**已做（第四刀）**：事件队列搬进 `native/events.h` / `events.mm` —— `emit`（40 多处调用）、`drainEvents`、`resetEvents`，队列本身（`NSMutableArray`）不再由 core 持有；core 只剩两行 `events() { requireReady(); return drainEvents(); }`。收益不在行数（992 → 982），而在**谁拥有数据**：事件流的唯一入口与唯一出口现在在同一文件里。

**待做**：键盘路径（`routeKeyEvent`/`adaptApplication`/`sendEvent:` swizzle）与 `pages`、`scroll`、`EmacsApp` 深耦合，仍留在 core —— 这是最后一刀，收益最低、风险最高，建议不做；`extern` 换 registry 访问器同理。

### B8 ❌ 不修（调研结论：没有替代品）
调研目标：能否用 `(frame-parameter frame 'window-id)` 直接拿 NSWindow number，从而删掉 `chromel--frame-handle` 里"临时改 title → 按 title 找窗口"的借用。
**实测否决**（`test/gui-smoke.el` 临时插桩，同一进程同一时刻读取）：
```
(frame-parameter nil 'window-id)  → "1"      ; 字符串，Emacs 自己的帧计数器
(chromel--native-inspect id)     → 1630     ; 真正的 NSWindow.windowNumber
```
NS 端口下 `window-id` 是 Emacs 内部编号（字符串），`outer-window-id` 为 nil，与 AppKit 无关。窗口标题借用保留；`unwind-protect` 已保证标题一定还原，token 里带 pid 与随机串，撞车概率可忽略。
（顺带修掉了同一条链上的真 bug：见 A7。）

## C. 行为与 UX

### C1 ✅ 延迟标签的命令路径有测试兜底
`chromel--command` 先在 raw-JS 开关上做判定、再 `chromel--ensure-browser`，最后才要求 `chromel--id`。新增两条 ERT：`chromel-command-materializes-a-deferred-tab-first`（断言调用顺序是 ensure → native，且 native 收到新建的 id）与 `chromel-command-refuses-a-tab-that-stayed-deferred`（仍 pending 时 `user-error`）。

### C2 ✅ 搜索引擎写死 DuckDuckGo
新增 `defcustom chromel-search-url`（默认 `https://duckduckgo.com/?q=%s`，要求含 `%s`），`chromel--normalize-url` 用 `format` 套用，查询串仍走 `url-hexify-string`。ERT 增加 3 条：默认模板、`%` 转义（`100%25`）、自定义模板生效；29/29 通过。
> 顺带发现：仓库里的 `chromel.elc` 是未跟踪的构建产物，`load` 会优先加载它，改完 `chromel.el` 直接跑 ERT 会测到旧逻辑（本轮先踩了一次）。建议后续在测试脚本里强制 `load` 源文件或先删 `.elc`。

### C3 ✅ 弹窗是真弹窗，保留 window.opener
原实现把 `target=_blank` / `window.open` 变成新标签：URL 对了，但页面拿到的是没有任何关系的顶层页，`window.opener` 为 null，`postMessage` 回不去，OAuth / 支付类流程会卡住。

现在 `OnBeforePopup` 返回 `false`：`preparePopupPage()` 先把 page 登记进 `pages`（`awaitingBrowser = true`，容器 1×1 隐藏挂在 opener 的窗口里），`CefWindowInfo`（hidden + ALLOY）、`CefClient`、`CefBrowserSettings` 交给 CEF，由 CEF 自己创建弹窗；`Client::OnAfterCreated` 负责把 CEF 视图收进 container（这一步**必须**按 client 自己的 `id_` 查 page —— CEF 的 browser id 与 page id 是两套序列，有 DevTools 后就会错开）。随后发 `popup-page` 事件 `{id,url,background}`，Elisp 的 `chromel--adopt-popup` 用**已有** id 建 buffer（绝不调 `chromel--native-create`）。

测试：`test/features.html` 加一个 `target=_blank rel=opener` 的链接与 `test/popup-child.html`，`gui-features` 断言「新 buffer 存在 + URL 正确 + 子页面能读到 `window.opener.document.title`」。踩坑：Chromium 88 起 `target=_blank` 默认 `noopener`，必须显式 `rel=opener`；`popupOpened` 那种 postMessage 断言有竞态，改成子页面直接读 opener 文档。

### C4 ✅ hints 测试按 URL 选标签，不再硬编码按键
`gui-hints` 原先发 `(unread-command-events '(?a ?a ?s))` 并强制 `chromel-hint-alphabet "as"`，前提是"只有两个可见链接"。可见数量一变（窗口高度、显示器、缩放），标签就变，测试随即超时。
现在 `chromel-test--follow-link-to` 用 `cl-letf` 替换 `chromel--read-hint`：从 overlay 返回的 hints 里挑 `:url` 以 `/hint-target` 结尾的那条，读它的真实 label（注意返回必须是 `(:label …)` plist，`chromel-follow` 会再拿它去 `prepare`）。
**验证**：`CHROMEL_TEST_ONLY=smoke,hints` PASS；并在 A2 把窗口放大到 1100×750 后仍然 PASS（旧写法在这一步必挂）。

### C5 ✅ 泵的空闲判定改问 native
`chromel_core.h` 新增 `int browser_count();`（只读 `browsers` + `settingsBrowsers`，**不**经 `requireReady`，CEF 未初始化时返回 0）；模块导出 `chromel--native-browser-count`；Elisp 新增 `chromel--native-has-browsers-p`，`chromel--pump-needed-p` 用它取代原先永不重置的 `chromel--settings-open`（该变量已删除）。`chromel-settings` 改为「先发 settings 命令、再 `chromel--ensure-timer`」，因为窗口是在那条命令里同步创建的。API 版本随之升到 2。ERT 新增 2 条并更新 2 条（无页面/无浏览器时停泵、设置窗口存在时继续泵、模块未加载时不问 native）。

### C9 ✅ 没有代理配置

CEF 的代理只认命令行：`--proxy-server` 或 `--proxy-pac-url`，都在浏览器进程启动时读一次。以前 Chromel 两者都没接，所以无论用户环境怎么配，页面永远直连。

现在 `chromel-proxy-pac-file` 接受 PAC 文件或 URL：native 在 `OnBeforeCommandLineProcessing` 追加 `proxy-pac-url`，Elisp 在 `chromel--start` 里先把它交过去。实测这个构建**取不到 `file://` 的 PAC**（静默退回直连），所以文件路径由 `chromel--pac-server-url` 在 `127.0.0.1` 起一个只回答 `/proxy.pac` 的 HTTP 服务喂给 Chromium；`http(s)://` 地址原样使用。

`scripts/smartproxy-to-pac.py` 把 SmartProxy 的完整备份转成 PAC：按 `activeProfileId` 选 profile，保留规则顺序，`whiteList` → DIRECT，协议映射 `PROXY/HTTPS/SOCKS4/SOCKS5`，未匹配主机默认 DIRECT（`--default-proxy` 可改）。针对用户实际导出的 44 条规则生成成功，46 行返回值；用本机 clash（`SOCKS5 127.0.0.1:7890`）实测：未匹配的 `example.org` 直连加载，命中的 `mikanani.me` 经代理加载出真实标题。

**验证**：`--proxy-server=127.0.0.1:9` 让两个站点都失败（证明命令行代理生效）；`file://` 与 `data:` 的 PAC 都静默退回直连；`http://127.0.0.1:<port>/proxy.pac` 的 PAC 生效；ERT 44/44（含 `chromel--pac-url` 起服务并回读脚本的用例）。

### C8 ✅ 权限请求无声拒绝

`Client` 之前没实现 `CefPermissionHandler`，于是通知、地理位置、摄像头/麦克风、剪贴板读取在 Alloy 风格下落到默认处理 = `CEF_PERMISSION_RESULT_IGNORE`，网页只会看到"用户拒绝"，用户什么也没看到。

现在 `native/permissions.mm` 停靠回调并上报 `permission` 事件，Elisp 在回显区问 `Allow <origin> to use <name>? (y or n)`，答案按「来源 + 权限名」记在本次会话的 `chromel--permission-answers` 里；`chromel-permission-policy` 可预置 `allow`/`deny`。策略拒绝会拒绝整条请求（一个回调只有一个答案），媒体请求按 `mediaBits` 原样回传。

验证：`test/gui-permission.el` 打开一个调 `Notification.requestPermission()` 的页面，断言"问了一次 → granted"、"第二次同来源不再问 → granted"。顺手确认了 `y-or-n-p` 在定时器回调里可用（CEF 泵在等待期间停摆无害，渲染进程本来就在等这个回调）。

### C7 ✅ 下载被静默丢弃

`CefDownloadHandler` 之前根本没实现，附件导航在 Alloy 下退回默认处理 = 取消，页面看起来"点了没反应"。现在 `native/downloads.mm` 决定路径（`chromel-download-directory`，默认 `~/Downloads`）、按 `name (1).ext` 避让重名、按 percent 去重上报进度；Elisp 在模式行显示百分比、在回显区报告结果。`test/gui-download.el` 覆盖"下载落地 + 内容正确 + 同名不覆盖"。

顺带记两个浏览器的脾气：① 同一页面第二次脚本触发的下载会被"多重自动下载"拦掉，需要真实点击（测试里第二份来自新标签页 + 点击）；② 刚交付过下载的页面不再执行脚本或导航，所以复用它做后续断言会看到"没有任何事件"。

### C6 ✅ 渲染进程崩溃后只剩空白页
渲染进程死掉时（内存耗尽、SIGSEGV、`kill -9`），Elisp 侧原先只能看到"不再有新事件"，页面冻结在白屏，用户没有任何提示。
现在 `Client::OnRenderProcessTerminated` 上报 `crashed`（`{status, code, message}`），Elisp 记住崩溃前的 URL、清掉 find 状态，并把标签导航到一个 `data:text/html` 错误页（"The page crashed / Renderer exited (status 9, code 0) / Press r to reload …"）；`r`（`chromel-reload`）在有崩溃标记时导航回原 URL 并清标记，`mode-line-process` 期间固定显示 `Crashed`。
`chrome://crash` 是 Chrome 层 URL，CEF 不提供（实测导航后无任何事件、URL 为空），所以回归手段是**自己杀渲染进程**：`test/gui-crash.el` 用 `ps` 找 `--type=renderer` 子进程并 `kill -9`，再断言出现错误页、`r` 能恢复。历史记录本来只收 `https?://`，`data:` 页不会污染它。
**验证**：ERT 37/37（新增事件路径与 `chromel--crash-reason` 两条）；`CHROMEL_TEST_ONLY=crash` PASS；完整套件 21/21。

## D. 文档

- ✅ `docs/architecture.md`：分层、外部消息泵、视图嵌入与坐标系、事件/命令、JS 往返、键盘双路径、焦点、生命周期、不变量、扩展点（README 顶部已链入）。
- README 明确：CEF 必须在 app bundle 内（`install-app.py` 的理由）、`C-c w E` 与 `s` 的分工、`chromel-allow-raw-javascript` 的取舍、session/history 文件位置与恢复命令。
- ✅ `CHANGELOG.md`：0.1.0 起按"崩溃与安全 / 交互 / 测试与构建 / 文档"分类。
- ✅ README 已补：CEF 为何必须在 app bundle 内、`chromel-allow-raw-javascript` 的取舍。

## 常用验证

```bash
./scripts/build.sh                       # 0 warning
emacs --batch -L . -L test -l test/chromel-test.el -f ert-run-tests-batch-and-exit
python3 scripts/test-gui.py              # 23 项，约 5 分钟，会抢焦点
CHROMEL_TEST_ONLY=smoke,hints python3 scripts/test-gui.py   # 子集
```

## 已知外部问题（不是本项目的 bug）

- **删除已被输入法接管的 frame 会让 Emacs 31.1 abort**：`make-frame` → 等待（哪怕 1 秒）→ `delete-frame`，崩溃于 `-[EmacsView selectedRange]`（经 `handleTSMEvent` 从 IMK 进入），随后 `emacs_abort`。`emacs -Q`、不加载 chromel、不启动 CEF 也能复现（5/5），属于 Emacs/macOS 交互缺陷。项目侧规避：`test/gui-smoke.el` 用 `make-frame-invisible` 代替 `delete-frame`（提交 `136f5e3`）。若将来要覆盖"删除 frame"的清理路径，需要先确认上游修好。
- **GitHub macOS runner 不可用**：`macos-14` 报 `The configuration 'macos-14-arm64-us-default' is not supported`；`macos-13` 被接受但长期 queued 直到 24 小时被取消。CI 的 `elisp` 作业可改 `ubuntu-latest`，`native` 作业保留手动触发。
