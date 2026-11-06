# Chromel 待办

快照：2026-11-06，分支 `p1-hardening`（= `master` = `origin/master`，提交 `9533404`）。

验证基线：`./scripts/build.sh` 0 warning / 0 error，ERT 28/28，`python3 scripts/test-gui.py` 19/19 连续两次全绿。

## 已完成（本轮）

- **P1 崩溃/安全**：`cef.lock.json` 入库；NSException 不越过模块边界；`mainFrame()` 统一守卫；`pumping` 用 RAII；`shutdown()` 不再跑嵌套 AppKit runloop 且两条路径都清理；observer 注销；IPC 空指针检查；`OnBeforeBrowse` 尊重 `userGesture`（特权 `chrome://` 页面必须由用户手势触发，Web Store 交接保留）；settings URL 规则收敛到 native 单一来源；`info()` 不再硬编码 Sandbox；`"javascript"` 有 `chromel-allow-raw-javascript` 开关。
- **P2 交互/性能**：`s` 归还页内搜索、Web Store 移到 `E`（README 与 meow 测试同步）；50 Hz 定时器按需启停（2 秒关停宽限期）；`selected`/layout 变更去重。
- **测试真因**：cmd+click 开新标签改用同窗切换（原先 `pop-to-buffer` 拆 frame，导致 `gui-hints` 只有半屏、标签退化成单字母）；`gui-features` 点击坐标避开视口右侧 16 px 不可命中带；test mode 关闭 Chromium 后台/遮挡节流；合成 Escape 先激活 App 再投递并重试。

## A. 工程护栏（建议优先）

### A1 测试可能跑旧 dylib
`scripts/test-gui.py:14-15` 只构建 `chromel-pump-probe`，模块编译失败时套件仍会用上一次的 `build/chromel-module.dylib` 跑完并"通过"（本轮实际撞到过）。
**做法**：构建 `chromel-module` 并校验返回码；必要时断言 dylib mtime 晚于 `native/*.mm|h`。
**验收**：故意在 native 代码里写错，套件必须立刻失败而不是变绿。

### A2 GUI 脚本依赖环境窗口尺寸
默认 frame 约 560×462 点，`gui-hints`/`gui-features` 的可见元素与坐标都隐含这个尺寸；`gui-controls.el:168`、`gui-hold.el:158`、`gui-scroll-modal.el:122` 已显式 `(set-frame-size nil 1100 750 t)`。
**做法**：所有 GUI 脚本统一在开头设固定尺寸（并在退出时还原）。
**验收**：在两种显示器/缩放设置下结果一致。

### A3 没有 CI
仓库无 `.github/`。**做法**：macOS runner 上 `build.sh` + ERT + `CHROMEL_TEST_ONLY=smoke,controls` 冒烟（GUI 全套太贵，可 nightly）。
**验收**：干净 clone 的 PR 能自动跑通构建与 ERT。

### A4 CEF 下载的架构判断
`scripts/fetch-cef.py:18` 用 `platform.machine()`，在 Rosetta 终端下会选错架构。**做法**：改读 `sysctl -n hw.optional.arm64` 或 `platform.uname().machine` + `arch` 校验。

### A5 CMake 缺省项
没有 `CMAKE_OSX_DEPLOYMENT_TARGET`，`CMAKE_BUILD_TYPE` 未给默认值（`build.sh` 传了 Release，IDE/CI 直连 CMake 时是空）。**验收**：裸 `cmake -S . -B build` 也能得到 Release 且部署目标明确。

### A6 smoke 二进制未接线
`build/chromel-smoke` 依赖 `NSBundle.mainBundle`，无法独立运行（报 "CEF helper missing; run scripts/build.sh"），且 `test-gui.py` 从不调用它。**做法**：要么嵌入 `EmacsChromel.app` 里运行，要么删掉并以 GUI 测试为准。

## B. 架构

### B1 `command()` 表驱动化
`native/chromel_core.mm:838-1066`：约 205 行 if/else 链，每个动作各自解析 JSON 并手写类型/范围判断。
**做法**：一张 `{name, arity, parse, run}` 表 + 请求结构体；未知动作仍抛 `Unknown browser action`。
**收益**：新增动作不再复制解析样板；argv 校验可单测。

### B2 空队列仍做 JSON 往返
`native/chromel_core.mm:1075-1080`：每 tick 都 `dataWithJSONObject:` 一次，即使队列为空。**做法**：序列化前加 `if (queue.count == 0) return "[]";`，并考虑用可变字符串缓冲累计事件。

### B3 DevTools 是死路
`native/chromel_core.mm:1060` 用 `new Client(0)`，而 `emit()` 对 id 0 直接返回（`:126-127`），`pageFor(0)` 也无效——DevTools 窗口不产生任何事件。**做法**：给 DevTools 专门 client/负 id，或显式声明"仅供人工调试、不参与事件"。

### B4 hints.js 每次 follow 从磁盘读
`chromel.el:838-840` 每次 `insert-file-contents "native/hints.js"`，而 `scroll.js` 是构建期内嵌（`CMakeLists.txt:32-34`）。**做法**：统一由 CMake 生成头文件，Elisp 侧只取字符串。

### B5 没有 Elisp↔模块 ABI 握手
升级 dylib 但旧 `chromel.el`（或反之）没有检测。**做法**：导出 `chromel--native-version`，`chromel--ensure-module` 里断言主版本。

### B6 testMode 渗进生产路径
`command()`/`click`/`initialize()` 里散落 `testMode` 分支。**做法**：收敛到单一 `isTestMode()` + 一处文档说明，避免将来在正式路径误开。

### B7 全局状态
21 个全局 defvar、单个 1039 行 TU、`pages/browsers/settings*` 都是文件级全局。已有 `Page` 结构，但没有会话对象。**做法**：先把 settings 相关 6 个全局收进一个 `SettingsState`，作为中间步。

### B8 用 frame title 找 NSWindow
`chromel.el:191-206` 的 `chromel--frame-handle` 临时改 frame title、调 `chromel--native-bind` 再改回。**先调研**：Cocoa 的 `(frame-parameter frame 'window-id)` 是否已给出 NSWindow number；能拿到就删掉这个 hack。

## C. 行为与 UX

### C1 延迟标签的半初始化
`chromel--pending`（`chromel.el:119`，判定见 `:219`、`:346`）的 buffer 在激活前没有浏览器/几何。所有命令都必须先 `chromel--ensure-browser`；补一个 ERT 覆盖"对 pending 标签发命令"。

### C2 搜索引擎写死 DuckDuckGo
`chromel.el:145` 硬编码 `https://duckduckgo.com/?q=`。**做法**：`defcustom chromel-search-url`（含 `%s`），默认值不变；`chromel--normalize-url` 用它。

### C3 弹窗丢失 `window.opener`
`OnBeforePopup`/`OnOpenURLFromTab` 一律抑制并由 Emacs 开新标签，脚本弹窗拿不到 opener。**做法**：至少写进 README 的"已知限制"；要支持则区分"用户手势链接"与"脚本 window.open"。

### C4 hints 标签依赖可见数量
`gui-hints` 曾因可见链接从 6 降到 2、标签退化成单字母而超时。**做法**：`test/gui-hints.el` 不假设标签长度/数量（按 `hints` 返回的 label 逐个敲），或固定窗口尺寸后断言完整列表。

### C5 打开过设置窗口后定时器不再空闲
`chromel--settings-open` 故意永不重置（native 拥有窗口生命周期），所以泵保持 50 Hz。**做法**：native 增加"是否还有任何 browser"查询（P2b），Elisp 用它决定是否停泵。

## D. 文档

- README 明确：CEF 必须在 app bundle 内（`install-app.py` 的理由）、`C-c w E` 与 `s` 的分工、`chromel-allow-raw-javascript` 的取舍、session/history 文件位置与恢复命令。
- 补 `CHANGELOG.md`，0.1.x 起按"崩溃/安全、交互、测试"三类记录。

## 常用验证

```bash
./scripts/build.sh                       # 0 warning
emacs --batch -L . -L test -l test/chromel-test.el -f ert-run-tests-batch-and-exit
python3 scripts/test-gui.py              # 19 项，约 4-5 分钟，会抢焦点
CHROMEL_TEST_ONLY=smoke,hints python3 scripts/test-gui.py   # 子集
```
