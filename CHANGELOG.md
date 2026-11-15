# 变更记录

按"崩溃/安全、交互、测试与构建、文档"分类。版本号跟随 `chromel.el` 的 `Version` 头。

## 0.1.0（未发布）

### 崩溃与安全

- `cef.lock.json` 入库：干净 clone 首次构建不再因缺少锁文件直接失败。
- Objective-C 异常不再越过模块边界（`@catch (NSException*)`），nil 视图、已销毁窗口等 Cocoa 故障转为 Lisp `error`。
- `GetMainFrame()` 统一走 `mainFrame()` 守卫；JS 求值只接受主帧回复且 token 必须匹配。
- `pump()` 的 `pumping` 改为 RAII；`shutdown()` 不再运行嵌套 AppKit 循环，两条路径都会清理页面、浏览器与观察者。
- IPC 参数在解引用前检查；`OnBeforeBrowse` 尊重 `userGesture`：特权 `chrome://` 页面必须由用户手势触发（Web Store 交接保留）。
- 设置页 URL 判定收敛到 native 单一来源，Elisp 不再维护第二套正则。
- `--no-sandbox` 未引入；`info()` 不再硬编码 "Sandbox: enabled"，而是报告真实情况。

### 交互

- `s` 归还页内搜索，Chrome Web Store 移到 `E`（`C-c w E`）；README 与 Meow 测试同步。
- 20 ms 定时器按需启停：没有页面时先运行 2 秒宽限期再停，新建页面重新起泵。
- 泵是否该继续运行改由 native 的 browser 计数回答（`chromel--native-browser-count`），设置窗口关掉后定时器也能真正停下；原先那个"永不重置"的开关已删除。
- `selected` 与布局调用做变更去重，静止页面不再每 tick 触达 native。
- 页面发起的新标签改为同窗切换（原先 `pop-to-buffer` 会拆开浏览器所在 frame，页面只剩半高）。
- 搜索引擎可配置：`chromel-search-url`（含 `%s`），默认仍为 DuckDuckGo。
- `chromel-allow-raw-javascript`：为"只发不收"的 JS 动作提供开关。
- 受管页面（设置/密码/扩展/Web Store）在独立窗口中打开，普通网页继续嵌入 Emacs。

### 交互

- DevTools 窗口改用专用 `DevToolsClient(owner)`：在 DevTools 里点开的链接会按所属页面打开新标签，不再是点了没反应；其余检查器事件仍不回传（没有对应 buffer）。

### 内部结构
- 管理窗口（settings / 密码管理器 / 扩展 / Web Store）整体移入 `native/settings.mm`：它自己的八个全局、四个 CEF 委托、URL 白名单与开关都在一处，宿主只通过 `openSettings`/`closeSettings`/`inspectSettings` 等语义接口访问；`chromel_core.mm` 1186 → 992 行。
- `create` / `layout` / `hide` 与窗口表移入 `native/page.mm`：页面状态、两张 id→对象表和所有"对某个 page 做的事"现在同处一个编译单元；`chromel_core.mm` 只留 CEF 回调与编排（1311 → 1186 行）。`Client` 通过 `makePageClient(int)` 工厂暴露，就绪检查通过 `requireBackendReady()` 复用同一份错误文案。
- 事件泵改成按需变频：CEF 用 `OnScheduleMessagePumpWork` 告诉我们有没有活（20 ms），连续 200 ms 没活就降到 250 ms 只排事件队列。一个 idle 标签页的 CPU 从 11.4% 降到 1.3%。JS 滚动与设置窗口仍强制 20 ms。

- `Page` 与两张 id→对象表（`pages`、`browsers`）连同 5 个 page 助手从 `chromel_core.mm` 搬进 `native/page.h` / `native/page.mm`，宿主层从 1311 行降到 1240 行。表仍是 `extern` 全局，这一刀只切编译单元。
- `command()` 不再是一条 205 行的 `if/else` 链：动作按名字放进 `browserActions()` / `settingsActions()` 两张表，派发只做一次查找。每个动作的代码与校验逻辑原样搬进自己的条目，行为未变（ERT 35/35、GUI 套件 20/20）。

### 测试与构建

- `gui-hold` 的稳态速度断言改成对整段采样做最小二乘斜率（原先逐帧 dy/dt 取 min/max）。实测斜率稳定在 899.9–900.3 px/s，而逐帧值会因一次迟到帧在 691–1164 之间跳——那是采样噪声，不是滚动不匀。单测超时从 55 s 放宽到 90 s，避免机器有负载时把"慢"误判成"失败"。
- 测试开关拆成三个明确的承诺：`CHROMEL_CEF_TEST_MODE`（存在 `test-*` 钩子）、`CHROMEL_CEF_TEST_QUIET`（不显示/不抢焦点）、`CHROMEL_CEF_TEST_HERMETIC`（mock keychain + 临时 profile），后两者默认跟随 MODE，因此现有测试无需改动；`info()` 会回报三个开关的取值。
- 生产进程调用 `test-*` 动作现在直接报 `Unknown browser action: <动作>`，不会再被静默吞掉。
- `scripts/test-gui.py` 的 `CHROMEL_TEST_ONLY` 会在筛选掉"播种"测试时自动补跑一条 `gui-smoke.el`，避免 `…-restored` 标题永远等不到（此前会一直挂到 55 秒超时）。

- GUI 测试统一在 `test/gui-frame.el` 固定的 1100×750 frame 里运行，几何断言不再随显示器/字体漂移；hints 测试改为按 URL 挑标签，不再硬编码按键序列。
- CEF 的 bundle 不再由 Elisp 从 `invocation-directory` 猜：新增 `chromel--native-bundle-path`（`NSBundle.mainBundle.bundlePath`），路径做 `file-truename` 兜底，软链/`open`/GUI 启动都不会再拿错 bundle（模块 API 升到 3）。


- `native/hints.js` 与 `scroll.js` 一样在构建期内嵌进模块，Elisp 不再每次 follow 读磁盘；脚本与 dylib 不会再出现版本错配。
- 原生冒烟宿主改为直接构建进 `ChromelRuntime.app/Contents/MacOS/ChromelRuntime`，可以脱离 Emacs 单独运行；`scripts/test-gui.py` 现在先跑它再拉起 19 个 GUI 进程（共 20 项）。


- GUI 套件启动前先构建 `chromel-module`；编译失败立即退出，避免用上一次的 dylib 跑出假绿。
- `gui-features` 的点击坐标避开视口右侧 16 px 的滚动条死区（`elementFromPoint` 实测 543/544 分界）。
- test mode 关闭 Chromium 的后台/遮挡节流；合成 Escape 先激活 App 再投递并重试，消除全屏下的偶发失败与输入法崩溃。
- 空闲 tick 不再把空事件队列序列化成 JSON（`events()` 直接返回 `[]`）。
- 延迟标签的命令路径补了 ERT（先建浏览器再发命令；仍为 pending 时报 `user-error`）。
- `scripts/fetch-cef.py` 按硬件架构选择 CEF（`sysctl hw.optional.arm64`），Rosetta 下不再下错包；新增 `--arch` 自检。
- CMake 默认 `Release` 与 `CMAKE_OSX_DEPLOYMENT_TARGET=13.0`。
- 新增 CI：Homebrew Emacs 跑 ERT；另一作业缓存 CEF、全量构建、拒绝编译警告、校验模块 API 版本。
- Elisp≠模块的 API 版本不一致时 `chromel--ensure-module` 直接报错并提示重新构建（当前 API = 2）。
- `gui-smoke` 不再删除第二个 frame，改为隐藏：AppKit 已把该窗口交给输入法之后，`delete-frame` 会在 Emacs 31.1/macOS 上 abort（`-[EmacsView selectedRange]` 经 `handleTSMEvent`），用 `emacs -Q` 去掉 Chromel 也能复现，属 Emacs 自身的问题。
- CI：`elisp` 作业改到 `ubuntu-latest`（`emacs-nox`），依赖原生模块的 5 条 ERT 用 `chromel-test--module-available-p` 跳过，其余在 Linux 上照跑；`native` 作业因托管 macOS runner 不可用改为手动触发。
- 提醒：`.elc` 已被 `.gitignore` 忽略，但它只要还在磁盘上就会被 `load` 优先加载——改了 `.el` 却测到旧逻辑（本轮亲历：API 版本升到 2 后 ERT 仍报 `(eql 2 1)`）。测试前先删 `chromel.elc`。

### 文档

- 新增 `docs/architecture.md`：分层、外部消息泵、视图嵌入与坐标系、事件/命令、JS 往返、键盘双路径、焦点、生命周期、不变量、扩展点。
- README 补充：CEF 为何必须位于 app bundle、`chromel-allow-raw-javascript` 的取舍、`window.opener` 不可用的已知限制。
