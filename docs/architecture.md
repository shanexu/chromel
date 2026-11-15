# Chromel 工作原理

本文说明 Chromel 如何在 **不修改 Emacs 源码** 的前提下，把一个真实的 Chromium（CEF）视图嵌进 Emacs 窗口，并让 Emacs 继续掌握标签、键盘和窗口管理。

适合在读代码前建立整体模型；具体的 API 细节以源码为准。

- Elisp 入口：`chromel.el`
- Emacs 模块：`native/module.mm`
- 宿主/浏览器层：`native/chromel_core.mm`（编排）、`native/page.h`/`page.mm`（页面结构与两张 id→对象表）、`native/settings.h`/`settings.mm`（Chrome 管理窗口）、`native/events.h`/`events.mm`（事件队列）、`native/helper.cc`、`native/hints.js`、`native/scroll.js`

---

## 1. 一句话原理

每个网页是一个独立的 `CefBrowser`，它的 Cocoa 视图被塞进 Emacs 某个窗口的 `contentView` 里，位置由 Emacs 的窗口几何决定；CEF 不自己跑事件循环，而是由 Emacs 的 20 ms 定时器一步步驱动。Emacs 负责"什么时候显示、显示在哪、按了什么键"，CEF 负责"网页长什么样、怎么响应鼠标"。

```
┌───────────────────────────── Emacs 进程 ─────────────────────────────┐
│                                                                      │
│  chromel.el                                                          │
│   ├─ 标签模型：buffer ⇄ page id                                       │
│   ├─ 键盘：chromel-mode-map / chromel-actions-map（Vimium 风格）       │
│   ├─ 20 ms 定时器 ──► chromel--native-pump ──┐                        │
│   └─ 事件处理 ◄── chromel--native-events ◄───┼──┐                     │
│                                              │  │                     │
│  chromel-module.dylib (module.mm)            │  │                     │
│   └─ 只做三件事：校验参数、调用 C++、把异常转成 Lisp error             │
│                                              │  │                     │
│  chromel_core.mm（宿主编排）                  ▼  │                     │
│   ├─ CefDoMessageLoopWork()  ◄────────────────┘  │                     │
│   ├─ 事件队列 NSMutableArray<NSDictionary*> ─────┘                     │
│   ├─ command()：navigate/scroll/click/eval/find/...                   │
│   └─ NSView 布局：把每个 page 的 container 摆到 Emacs 窗口里           │
│                                                                      │
│  NSWindow (Emacs frame)                                              │
│   └─ contentView                                                     │
│       ├─ Emacs 自己的文本区                                            │
│       └─ container(NSView) ── CefBrowserView ── 网页渲染              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
              │ CEF 进程间协议
              ▼
   ChromelRuntime.app / Chromel Helper (Renderer ×N, GPU, Plugin, Alerts)
```

---

## 2. 为什么是这个架构

| 方案 | 问题 |
|---|---|
| Emacs 内置 `xwidget`（WebKit） | macOS 上不可用/受限，且需要重编 Emacs |
| 独立浏览器 + IPC | Emacs 拿不到原生视图，窗口/标签/焦点无法和 Emacs 统一 |
| 嵌入 WebKit（WKWebView） | 功能与扩展生态远弱于 Chromium，无法装 Chrome 扩展 |
| **同进程 CEF + 原生 NSView**（本项目） | 需要自己驱动 CEF 事件循环、自己处理焦点与键盘；换来完整 Chromium 和 Emacs 原生窗口管理 |

代价写在后面"已知取舍"里：CEF 与 Emacs 共享同一个 `NSApplication` 和主线程，任何阻塞或异常都会直接伤到编辑器，所以代码里大量精力花在**边界防护**上。

---

## 3. 三层职责

### 3.1 `chromel.el`（用户态）

- **标签模型**：`chromel--pages` 是 `page-id → buffer` 的哈希；每个 buffer 用 `chromel-mode`（派生自 `special-mode`），buffer-local 变量记录 url/title/find 状态等。
- **命令**：`chromel`、`chromel-open-url`、`chromel-next-tab`、`chromel-follow`、`chromel-find`、`chromel-settings` 等。
- **键盘**：Emacs 侧一套 Vimium 风格键位；CEF 侧持焦时由 native 的按键前缀状态机接管（见 4.7）。
- **定时器**：`chromel--tick` 每 20 ms 驱动 CEF（见 4.1），没有页面时自动休眠。
- **持久化**：会话/历史 JSON（见 4.13）。

### 3.2 `native/module.mm`（模块边界）

唯一职责是**把 C++ API 安全地暴露给 Lisp**：

- 先校验参数个数与类型（`env->extract_*` + `non_local_exit_check`），不合法直接返回；
- 用 `try/catch` 把 `std::exception`、`NSException`、未知异常全部转成 Lisp `error`，**绝不让 Objective-C 异常穿过 Emacs 的 C 栈**（那会 abort 整个编辑器）；
- 注册为 `chromel--native-{init,bind,create,layout,hide,command,pump,events,info,inspect,is-settings-url,shutdown}`。

### 3.3 `native/chromel_core.mm`（宿主层）

- CEF 初始化（`CefInitialize`）、`NSApplication` 改造、事件泵；
- 页面本身的结构（`Page`）、`pages`/`browsers` 两张表、`create`/`layout`/`hide` 与窗口表 `windows`/`windowFor` 都在 `native/page.h` / `native/page.mm`；宿主层只负责 CEF 回调与编排，需要 `CefClient` 时通过 `makePageClient(int)` 工厂拿；
- 每个 page 的 `CefBrowser`、`NSView` 容器、几何布局；
- 命令执行 `command()` 与事件收集 `emit()`；
- 设置窗口（`chrome://settings` 等）与 DevTools；
- 关闭流程与 CEF 生命周期。

---

## 4. 核心机制

### 4.1 外部消息泵：CEF 不拥有事件循环

CEF 默认会跑自己的 `CefRunMessageLoop()`，那会和 Emacs 的 `NSApplication` 事件循环打架。Chromel 的做法：

```cmake
# CefSettings
external_message_pump = true;
```

```objc
// chromel_core.mm：CEF 说"还有活"时置位，泵之前清零
void OnScheduleMessagePumpWork(int64_t delayMs) override { pumpPending = delayMs >= 0; }
```

消息循环的"心跳"仍来自 Elisp，但**频率由 CEF 决定**：

```elisp
(chromel--arm-tick (if (chromel--caffeinated-p) 0.02 0.25))   ; 有活 50 Hz，idle 4 Hz
```

`pump_pending()` 还替 CEF 补了两类它不会排程的工作：活跃的 JS 滚动动画（渲染进程自己的时钟）与设置窗口。连续 10 次没有活才降频，且降频/升频都不额外补一帧——否则帧会成对到达，页面滚动速度会抖动。

`chromel--tick` 做四件事：`native-pump`（内部就是 `CefDoMessageLoopWork()` 一次）→ 取事件 → 分发事件 → `chromel--sync`（对齐几何/选中状态）。

好处：CEF 的每一步都发生在 Emacs 主线程的已知位置，不会被 CEF 的嵌套循环卡住；调试时 `M-x chromel-diagnostics` 能看到泵的状态。代价：CEF 的定时器精度受 20 ms 限制（视频播放、动画仍由渲染进程自己跑，不受影响）。

**空闲策略**：没有页面、没有 deferred 标签、也没有任何 CEF browser 时，泵会先运行 2 秒宽限期再停（等 CEF 异步关闭浏览器），之后定时器置 nil；新建页面时 `chromel--ensure-timer` 重新起泵。

「还有没有 browser」由 native 回答（`chromel--native-browser-count`，只读 `browsers` + `settingsBrowsers`，不启动 CEF），因为设置窗口的 browser 不在 `chromel--pages` 里。Elisp 侧不再维护「设置窗口可能还开着」的猜测标志。

### 4.2 视图嵌入：一个隐藏容器 + 坐标系换算

```objc
// create()
NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
container.hidden = YES;
[window.contentView addSubview:container];

CefWindowInfo info;
info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;   // 普通网页用 Alloy
info.SetAsChild(container, NSMakeRect(0, 0, 1, 1));
CefBrowserHost::CreateBrowserSync(info, client, url, settings, ...);
```

先用 1×1 隐藏容器占位，是为了让 CEF 有一个合法的父视图；真正的尺寸在 `layout()` 里设置：

```objc
// Elisp 传入的是 window-inside-pixel-edges（左上原点）
double cy = host.isFlipped ? y : NSHeight(host.bounds) - y - height;
container.frame = NSMakeRect(x, cy, width, height);
```

- Cocoa 默认原点在左下、AppKit 视图通常 flipped；Emacs 的坐标系是左上。`isFlipped` 分支负责这一层换算；
- 尺寸变化后调用 `NotifyMoveOrResizeStarted()`，否则 CEF 内部的合成器仍按旧尺寸绘制；
- 几何没变时 Elisp 侧会跳过调用（`chromel--sent-geometry` 去重）。

### 4.3 窗口识别：临时改标题

Emacs 不暴露 `NSWindow*`。Chromel 的办法是"打标记再找回来"：

1. Elisp 把 frame title 临时改成随机 token；
2. `chromel--native-bind(token)` 在 `[NSApp windows]` 里按 title 找到窗口，登记 `windowNumber`，返回；
3. 立刻恢复原标题。

拿到 `windowNumber` 后即可在 native 侧取回窗口、拿到 `contentView` 和几何。这是一个刻意的取舍：不做 Emacs 私有结构体解析，代价是绑定瞬间标题会闪一下（通常不可见）。

### 4.4 事件上行：队列 + JSON

native 侧不回调 Lisp（CEF 的回调可能来自任意线程），而是**只往队列里塞数据**：

```objc
void emit(int id, NSString* type, NSString* value) {
  if (!id) return;                       // 0 = 设置窗口命令，不回报
  [queue addObject:@{@"id": @(id), @"type": type, @"value": value}];
}
```

Elisp 每 tick 调一次 `chromel--native-events`，native 把整个队列 `NSJSONSerialization` 成数组后清空。目前的事件类型：

| 类型 | 含义 |
|---|---|
| `title` / `url` | 页面标题、地址变化 |
| `loading` / `loaded` / `error` | 加载生命周期（`error` 会带上错误码与描述） |
| `focus` | 页面获得/失去焦点 |
| `scroll-key` | CEF 侧接管的 j/k 等滚动键（用于 Elisp 同步状态） |
| `find` | 查找结果（当前/总数） |
| `chrome-ui` | 页面请求打开 `chrome://…` 等受管页面 |
| `popup-page` | 页面弹出了一个真实弹窗（JSON `{id,url,background}`），新页面已由 native 建好 |
| `popup` / `popup-background` | 弹窗兜底：native 拒绝托管时把 URL 交给 Elisp 开新标签 |
| `eval` | JS 求值结果（带 token） |
| `crashed` | 渲染进程死了（JSON `{status, code, message}`），页面已不可用 |
| `closed` | 浏览器已销毁 |

队列是**单生产者/单消费者**：CEF 回调发生在主线程的泵调用内，Elisp 也在主线程取，因此不需要锁。

### 4.5 命令下行：一张 action 表

Elisp 所有操作最终都走同一个入口：

```elisp
(chromel--native-command page-id action argument-json)
```

`command()` 是一张表（`browserActions()` / `settingsActions()`）：派发只做一次 `map` 查找，每个动作是一个自带参数校验的命名条目，不再依赖 `if/else` 的先后顺序。设置窗口没有页面，用 id 0 走另一张表。主要动作：

| 动作 | 说明 |
|---|---|
| `navigate` / `reload` / `back` / `forward` / `stop` | 导航 |
| `scroll` / `scroll-settings` | 像素级滚动（含动画），见 4.9 |
| `selected` / `focus` / `unfocus` / `focus-parent` | 焦点与"哪个页面在响应用户" |
| `click` | 合成鼠标事件（hints、新标签点击） |
| `find` / `find-stop` | 页内查找 |
| `eval` | 注入 JS 并等待返回（见 4.6） |
| `javascript` / `javascript-focused` / `javascript-frame` | 只发不收（`chromel-allow-raw-javascript` 控制） |
| `devtools` / `close` | DevTools、关闭页面 |
| `settings` / `close-settings` | `chrome://settings` 等受管页面 |
| `test-*` | 仅 `CHROMEL_CEF_TEST_MODE=1` 下可用的测试钩子；生产进程里它们会直接报 `Unknown browser action`，而不是被静默忽略 |

参数一律以 JSON 字符串传递（`argument`），native 侧用 `NSJSONSerialization` 再解析，并逐个检查类型与范围（坐标 < 10^7、必须是有限数等）。未知动作抛 `Unknown browser action`，由模块边界转成 Lisp error。

### 4.6 JS 求值往返

```
Elisp:  token = "e<N>";  发送 eval(token, script)
native: 记录 pendingEval = token
        主帧 SendProcessMessage("chromel.eval", [token, script])
renderer(helper.cc): 在主帧上下文执行脚本，postMessage 回 "chromel.eval.result"
native: OnProcessMessageReceived 校验 frame->IsMain() 且 token 匹配 → emit("eval", result)
Elisp:  chromel--eval 轮询（pump + accept-process-output），5 秒超时
```

关键约束：**只接受主帧**的回复，且 token 必须与最近一次请求一致，避免 iframe 或过期请求污染结果。返回的是数据（JSON/字符串），不是 Lisp 代码，不会被 `eval`。

### 4.7 键盘：两条路径 + 前缀状态机

**路径 A：Emacs 读键（默认）**

页面 buffer 用 `chromel-mode-map`：`j/k` 滚动、`g/G` 首尾、`f` hints、`/` 查找、`H/L` 历史、`C-c w` 前缀进入 `chromel-actions-map`（其中 `s` 是查找、`E` 是扩展商店）。这些键由 Emacs 自己解释，不经过 CEF。

**路径 B：CEF 持焦（页面输入框、原生控件）**

Chromel 在 `NSApplication` 上 swizzle 了 `sendEvent:`：

```objc
[NSApp sendEvent:] → 先交给 routeKeyEvent(event)
                      ├─ 返回 YES = 已消费（不再下发）
                      └─ 返回 NO  = 交给原始实现
```

`routeKeyEvent` 负责：

- **单键**：`j/k` 转成像素滚动；`Escape` 先 `unfocus` 再合成一个 `Control-G`（所以在页面里按 Esc 等于 Emacs 的 `keyboard-quit`）；
- **前缀**：`Ctrl-x`、`Ctrl-c`、`Ctrl-h`、`Opt-x` 被"翻译"成 Emacs 能识别的组合，保证 CEF 持焦时仍能按 `C-x C-f`、`C-c` 等；
- **长按**：`KeyDown` 的 repeat 被吞掉，滚动由自己的动画驱动（避免系统重复率影响速度）；
- **鼠标/滚轮**：先停止正在进行的键盘滚动，再把事件交回 CEF。

为了不和 Chromium 的事件处理递归，`NSApplication` 被加上 `CefAppProtocol` 与 `isHandlingSendEvent` 标志（CEF 要求宿主这样做，否则 `sendEvent` 会无限重入）。

### 4.8 焦点模型

三份状态必须一致：

1. **Emacs 侧**：哪个 window 是 `selected-window`（`chromel--sync` 计算，只在变化时下发 `selected 1/0`）；
2. **native 侧**：`page->selected`，决定是否把键盘事件交给这个 page；
3. **CEF/renderer 侧**：页面里是否有可编辑控件持焦——renderer 在 `OnFocusedNodeChanged` 时发 `chromel.input-focus`，native 记在 `page->inputControl`。

`ownsFocus()` = 页面被选中且没有输入控件在编辑；此时 j/k 走"滚动"语义，否则走"打字"语义。`unfocus` 会把 CEF 焦点还给 Emacs 窗口，避免出现"两个光标"。

### 4.9 滚动

- 键盘滚动在 native 里做**像素级动画**：`scrollStep`（默认 60 px）、`scrollDuration`（140 ms）、`scrollSpeed`（900 px/s），每帧 `SetPosition`；
- 鼠标滚轮与拖动滚动条仍由 CEF 自己处理；
- 页面里按住的 `j/k` 由 `OnPreKeyEvent` 接管，并忽略自动重复，直到 `KeyUp`；
- iframe 内滚动会先定位到焦点帧，再在该帧执行（`scrollFrame`）。

### 4.10 新标签、设置窗口与弹窗

- `target=_blank` / `window.open` 是**真正的 CEF 弹窗**：`OnBeforePopup` 返回 `false`，只把 `CefWindowInfo`（hidden 1×1、ALLOY）、`CefClient` 与 `CefBrowserSettings` 填好交给 CEF。页面本身由 `preparePopupPage()` 预先登记（`awaitingBrowser = true`），等 `Client::OnAfterCreated` 把 CEF 的视图收进该 page 的 container，再发 `popup-page` 事件（JSON `{id, url, background}`）让 Elisp 用一个**已存在**的浏览器 id 建 buffer（`chromel--adopt-popup`，绝不走 `chromel--native-create`）。
- 因为弹窗是 CEF 自己创建的，`window.opener` 与 `postMessage` 都保持；`gui-features` 里有断言：子页面必须能读到 `window.opener.document.title`。注意 Chromium 88 起 `target=_blank` 默认带 `noopener`，测试 fixture 用 `rel="opener"` 显式打开。
- native 拒绝托管（例如 opener 已经关掉）时退回旧路径：发 `popup` / `popup-background`，由 Elisp 开新标签，此时没有 opener。
- `chrome://settings`、`chrome://extensions`、`chrome://password-manager`、Chrome Web Store 走**独立顶层窗口**（`CEF_RUNTIME_STYLE_CHROME` + 工具栏），因为它们需要 Chrome 的 WebUI 资源与窗口级 UI。判定由 native 的 `is_settings_url()` 单点负责，Elisp 通过 `chromel--native-is-settings-url` 调用，避免两套规则漂移。
- 渲染进程崩溃（OOM、SIGSEGV、被 `kill -9`）时，`Client::OnRenderProcessTerminated` 发 `crashed`。`OnBeforeClose` 不会来——浏览器对象还活着，只是没有渲染进程——所以 Elisp 不销毁标签，而是记住当前 URL、清掉 find 状态、把标签导航到一张 `data:text/html` 错误页（说明原因并提示 `r`）。`chromel-reload` 见到崩溃标记时不是 `reload`（那会重载错误页），而是 `navigate` 回崩溃前的地址。`data:` 页不进历史（历史只收 `https?://`）。
- `chrome://crash` 是 Chrome 层 URL，CEF 不提供，所以崩溃回归只能靠外部杀进程：`test/gui-crash.el` 用 `ps` 找 `--type=renderer` 子进程并 `kill -9`。
- 页面发起的导航若指向 `chrome://` 受管页面，要求 `userGesture` 才放行（防止恶意重定向打开特权页面）；指向 Web Store 的则允许（这是项目刻意保留的扩展安装路径）。

### 4.11 hints（f 键）

1. Elisp 把 `native/hints.js`（构建期内嵌进模块，首次调用后缓存在 `chromel--hints-source`）注入当前页面（`eval`，带本次会话 token）；
2. 脚本枚举可点击元素，过滤不可见项（`display:none`、零尺寸、视口外、被遮挡——用 `elementFromPoint` 判断，并穿透 shadow DOM）；
3. 为每个候选生成多字母标签（字母表可配置，至少 2 个不同字母），返回 `[{label, url, tag, title}, …]`；
4. Elisp 用 `read-key` 逐字母收窄，每敲一个字母调一次脚本的 `filter`；
5. 唯一匹配后执行 `click` / `focus` / 复制链接；`C-g` 取消并清掉覆盖层。

标签长度由候选数与字母表容量决定（必须保证唯一），因此候选越多、标签越长。

### 4.12 生命周期与关闭

```
chromel--start → module-load → native-init(profile) → CefInitialize
                                                    ├─ 创建 ChromelRuntime 的 helper 进程
                                                    └─ 安装 resign-active/key 观察者
...
kill-emacs → chromel--shutdown → native-shutdown
                ├─ CloseBrowser(true) 全部页面
                ├─ 最多 3 秒泵，等 onBeforeClose
                ├─ 摘掉观察者、清空容器
                └─ 若还有浏览器/设置窗口 → 跳过 CefShutdown 并 NSLog
```

**CEF 在同一个进程里只能初始化一次**，所以 `chromel--start` 用 `chromel--initialized` 守卫，重复调用直接报错而不是尝试重启。跳过 `CefShutdown` 是有意的：宁可泄漏到进程退出，也不要在 Emacs 关闭路径上崩掉。

### 4.13 下载

`Client` 同时实现 `CefDownloadHandler`（`native/downloads.mm` 持有状态，core 只做转接）。`OnBeforeDownload` 返回 **bool**：CEF156 的语义是"返回 true 并调用 callback 才继续"，返回 false 会退回默认处理——在 Alloy 风格下默认处理就是取消，所以"什么都没发生"曾经是默认行为。

路径由 native 决定：`set_download_directory` 只记录，`start_download` 才 `create_directories`，因为 Emacs 没有下载搁架可以点"另存为"。重名用 `uniquePath()` 变成 `name (1).ext`；`suggestedFileName()` 取 `std::filesystem::path(...).filename()`，防止页面指定 `../../x` 逃出目录。进度按 `(browserId, percent)` 去重后才 `emit` 一条 `download` 事件，Elisp 只负责模式行与回显区。

两个容易踩的浏览器行为：同一页面第二次由脚本触发的下载会被 Chromium 以"多重自动下载"静默拒绝（需要用户手势，测试里用一次真实点击）；并且**刚完成下载的页面不再执行脚本和导航**，所以测试的第二份下载来自一个新标签页。

### 4.14 权限请求

两个入口，都在 browser process 的 UI 线程：`CefPermissionHandler::OnRequestMediaAccessPermission`（getUserMedia 的摄像头/麦克风，`CefMediaAccessCallback`）与 `OnShowPermissionPrompt`（其余，`CefPermissionPromptCallback`）。两者都是"返回 true 并稍后调用回调"，返回 false 就走默认处理——Alloy 风格下默认是**拒绝**（`CEF_PERMISSION_RESULT_IGNORE`），所以没写 handler 时网页看到的永远是"用户拒绝"。

回调必须恰好执行一次，而 Emacs 要问人。`native/permissions.mm` 把回调连同 origin、权限名一起停在一个 `unordered_map<uint64_t, Pending>` 里，emit 一条 `permission` 事件（`{id, origin, permissions:[…]}`），等 Elisp 用 `chromel--native-permission-reply` 回来再执行。停靠期间渲染进程只是等待，泵停不停都不影响它；真正需要注意的是 `shutdown()` 前必须 `cancel_prompts()`，否则回调会挂在已经拆掉的 browser 上。

媒体请求的放行不是布尔值：`CefMediaAccessCallback::Continue` 要求把 `requested_permissions` 的位原样回传，所以 `Pending` 同时存 `mediaBits`。普通提示用 `CEF_PERMISSION_RESULT_ACCEPT` / `DENY`。

一次请求只有一个回调，因此 Elisp 的决策是"整条请求"级别的：只要有一项被策略拒绝，就整条 `deny`；否则把所有 `ask` 的类型合并成一句问题问一次。`OnDismissPermissionPrompt`（导航、关页、Chromium 自己回答）来的时候只需丢掉停靠的回调，不要再回答。

### 4.15 持久化

数据目录默认 `~/chromel/`（可用 `chromel-data-directory` 覆盖）：

| 文件 | 内容 |
|---|---|
| `profile/` | 真正的 Chromium profile：cookie、localStorage、扩展、密码库 |
| `session.json` | 标签顺序、当前选中、最近关闭的标签（版本号为 1，带校验） |
| `session.previous.json` | 上一次会话，用于崩溃/误关恢复 |
| `history.json` | 访问历史（URL 去重、条数上限） |

写入策略：先写同目录临时文件 → `set-file-modes 600` → `rename-file` 覆盖，保证不会读到半个 JSON；读取用 `json-parse-buffer`（不 `eval`），版本不符则明确报错而不是静默丢数据。

---

## 5. 不变量（改代码前请先读）

| 不变量 | 位置/后果 |
|---|---|
| 所有 CEF 调用必须在 Cocoa 主线程 | `checkThread()`；违反直接抛错 |
| CEF 绝不拥有事件循环 | `external_message_pump` + 空 `OnScheduleMessagePumpWork`；跑 `CefRunMessageLoop` 会冻结 Emacs |
| 异常不跨模块边界 | `module.mm` 三个 catch；漏一个就是 Emacs abort |
| 任一时刻只有一个 page 响应键盘 | `selected` + `ownsFocus()`；否则两个页面同时滚动 |
| `CefShutdown` 只在没有浏览器时调用 | 否则渲染进程析构期崩溃 |
| 设置 URL 判定只有一个来源 | native `is_settings_url()`；Elisp 不得再写一套正则 |
| native 回调只入队，不直接调 Lisp | `emit()`；跨线程调用 Lisp 会崩 |
| JS 只回数据，不回代码 | `chromel.eval.result` 只做字符串/JSON 解析 |

---

## 6. 线程模型

- **主线程（Cocoa/Emacs）**：`CefInitialize`、所有 `command()`、`layout()`、泵、事件队列；
- **CEF 内部线程**：网络、IO、合成器；回调通过 `CefPostTask(TID_UI, …)` 回到主线程；
- **渲染进程**：独立进程（`Chromel Helper (Renderer)`），执行页面 JS、`hints.js`、`scroll.js`；
- **GPU/Plugin/Alerts**：其余 helper 进程。

Elisp 永远在主线程；`chromel--eval` 的"等待"不是阻塞式 `sleep`，而是 `accept-process-output` + 泵，期间 Emacs 仍可响应 `C-g`。

---

## 7. 进程模型与安装

```
Emacs.app/Contents/
├─ MacOS/Emacs                     ← 宿主（非沙盒）
├─ Frameworks/
│  ├─ Chromium Embedded Framework.framework
│  └─ Chromel Helper (Renderer/GPU/Plugin/Alerts).app
└─ Resources/emacs-chromel-runtime.json   ← 安装标记 + 版本
```

- CEF 的沙盒要求 framework 位于**正在运行的 app bundle 内**，所以 `scripts/install-app.py` 把 framework 与 helpers 拷进 `Emacs.app` 并重新签名（原 app 先完整备份）；
- **chromel 模块本身不在 app 里**：`chromel-module.dylib` 留在仓库的 `build/`，Elisp 通过 `chromel-native-module` 指向它。因此改代码不需要重装 app，只有换 CEF 版本才需要重跑安装脚本；
- `ChromelRuntime.app` 是构建产物的"运行时模板"，`install-app.py` 负责把它搬进真正的宿主。

---

## 8. 打开一个网页的完整时序

```
用户 M-x chromel RET https://example.com
 │
 ├─ chromel--make-tab        建 buffer，记 url，pending=t
 ├─ chromel--start           首次：module-load → native-init → CefInitialize
 ├─ chromel--ensure-browser  native-create(window, url)
 │                            ├─ 1×1 隐藏 container
 │                            └─ CreateBrowserSync(Alloy)
 ├─ chromel--sync            native-layout(id, handle, x,y,w,h)
 │                            └─ container.frame = ...，NotifyMoveOrResizeStarted
 │
 │  （20 ms 后）
 ├─ chromel--tick            native-pump → CefDoMessageLoopWork()
 │                            └─ CEF 网络/渲染推进
 ├─ events                   [{"type":"loading"}, {"type":"title",...}]
 ├─ handle-event             buffer 名、mode line 更新
 └─ sync                     几何/选中未变 → 不发 native 调用
```

---

## 9. 测试基础设施

| 层 | 手段 |
|---|---|
| 纯 Elisp 逻辑 | `test/chromel-test.el` 等 35 个 ERT（`emacs --batch`，无 GUI；缺原生模块时 5 条自动跳过，故 Linux CI 也能跑） |
| 真实渲染/输入 | `scripts/test-gui.py` 拉起独立 Emacs 进程（统一 `-l test/gui-frame.el` 固定在 1100×750 的 frame），本地 HTTP fixture，`CHROMEL_CEF_TEST_MODE=1`（临时 profile、mock keychain、禁用后台节流） |
| 事件泵 | `chromel-pump-probe` 记录 `NSApp.run` 重入次数（必须为 0） |
| 原生冒烟 | `build/ChromelRuntime.app/Contents/MacOS/ChromelRuntime --smoke-test <临时 profile>`，`test-gui.py` 在拉起 GUI 之前自动跑一次 |
| 构建门禁 | 套件启动前先构建 `chromel-module`，失败即退出（避免用旧 dylib 跑绿） |

GUI 套件共 22 个脚本，覆盖渲染、几何、焦点、滚动、会话、设置窗口、hints、Escape、崩溃、下载与权限等；加上原生冒烟共 23 项。

`CHROMEL_TEST_ONLY=a.el,b.el` 可只跑子集（原生冒烟总会先跑）。但 fixture 的标题在同一个 profile 里第一次是 `…-ready`、之后才是 `…-restored`，所以过滤掉"播种"的那一条会让 `…-restored` 永远等不到标题。`test-gui.py` 检测到筛选后的第一条不是播种测试时，会自动在前面补一条 `gui-smoke.el`。

---

## 10. 已知取舍与限制

- **标签是 Emacs 的 buffer/window，不是 Chromium 的 TabStrip**：所以没有 Chromium 的标签栏、标签组、标签搜索；
- **弹窗是单层的**：每个弹窗都是独立 page（独立 `CefBrowser`），共享同一个 profile，但弹窗里的 `target=_blank` 会再开一个标签，不形成浏览器意义上的 window 层级；
- **DevTools 只回传弹窗**：DevTools 窗口有自己的 `DevToolsClient(owner)`，在浏览器注册表里占一项（`shutdown()` 与计数都依赖它）；除“用户在 DevTools 里点开链接”会按所属页面开新标签外，它的 title/URL/焦点等事件不回报——那些属于检查器，没有对应的 Emacs buffer；
- **设置窗口一次一个**：已打开时再请求另一个 `chrome://` 页面不会切换 target（既有行为）；
- **不做 Chrome 同步/书签**：这些功能需要 Google 账号体系，当前版本有意不实现；下载只落到固定目录，没有搁架、列表或断点续传界面；
- **CEF 版本固定**：`cef.lock.json` 锁定版本与 SHA-1，升级需要重新构建并跑完整套件（API/行为差异主要出现在 `CefWindowInfo`、runtime style 与 sandbox）。

---

## 11. 扩展点

**加一个命令**：在 `chromel--command` 里发新 action → 在 `chromel_core.mm` 的 `browserActions()`（或设置窗口的 `settingsActions()`）里加一个条目 → 需要回传就加事件类型 → 在 `chromel--handle-event` 加 `pcase` 分支。

**加一个事件**：`emit(id, @"type", value)` → Elisp `chromel--handle-event` 加分支；注意 `id == 0` 会被丢弃。

**改键盘行为**：Emacs 侧改 `chromel-mode-map` / `chromel-actions-map`；CEF 侧改 `routeKeyEvent()`，并确认返回值语义（`true` = 吞掉）。

**加设置类页面**：只在 `is_settings_url()`/`is_privileged_chrome_url()` 里加规则，不要在 Elisp 里另写正则。

---

## 12. 术语

| 术语 | 含义 |
|---|---|
| page | 一个 `CefBrowser` + 一个 Emacs buffer，即"标签" |
| container | 承载 CEF 视图的 `NSView`，由 Emacs 窗口几何决定位置 |
| pump | 一次 `CefDoMessageLoopWork()`，由 20 ms 定时器驱动 |
| browser count | native 侧 `browsers` + `settingsBrowsers` 的数量，用来判断泵是否还需要运行 |
| selected | 当前接收键盘的页面（Emacs window 选中且无 minibuffer 激活） |
| ownsFocus | 页面被选中且没有输入控件在编辑，此时 j/k 表示滚动 |
| settings window | `chrome://settings` 等受管页面的独立顶层窗口 |
| test mode | 拆成三个开关：`CHROMEL_CEF_TEST_MODE=1`（存在测试钩子）、`CHROMEL_CEF_TEST_QUIET`（不 Show/Activate/抢焦点，默认跟随 MODE）、`CHROMEL_CEF_TEST_HERMETIC`（mock keychain + 临时 profile，默认跟随 MODE） |
