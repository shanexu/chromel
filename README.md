# Chromel — Emacs 中的原生 CEF 浏览器

Chromel 是 macOS 上的 Emacs 原生浏览器插件：一个网页对应一个 Emacs buffer，Chromium 视图作为 Emacs 窗口内的 `NSView` 显示。借鉴 Appine 的同进程原生视图方案，使用 CEF 替代 WebKit，不依赖 Qt，不需要修改或重新编译 Emacs 源码；可以安装到现有 `Emacs.app`，也可以使用独立应用副本。

首个版本提供网页浏览、导航、独立 profile、Chromium 设置页、浏览历史和 DevTools，支持手动添加密码后的自动填充，以及 Chrome Web Store 安装和扩展管理。普通网页嵌入 Emacs，设置和管理页面在独立窗口中打开。暂不支持 Chrome 同步、书签管理或下载管理。

提供 Vimium 风格的键位、关闭页面恢复、会话自动保存和延迟恢复。Meow 是可选适配，不需要安装即可使用全部浏览器键位。

## 开始使用

要求：macOS 13+、Cocoa/NS 版 Emacs 29+（启用动态模块）、Xcode Command Line Tools、CMake、Python 3。原生模块必须与运行 Emacs 的 CPU 架构一致。当前本机验证环境是 Apple Silicon + Emacs 32。

将源码放在任意目录。以下示例中的 `/path/to/chromel` 请替换为实际的源码目录，后续命令均在该目录执行。

```sh
cd /path/to/chromel
./scripts/build.sh
```

首次构建下载 `cef.lock.json` 中固定版本的 CEF，按官方 SHA-1 校验后解包到 `.deps/`，产物放在 `build/`。网络中断可以重跑，已完整下载的分段会复用。建议预留 2 GB 可用空间。

### 安装到现有 Emacs.app

先退出目标 Emacs，在系统终端执行：

```sh
cd /path/to/chromel
python3 scripts/install-app.py /Applications/Emacs.app
```

安装后照常通过 Dock、Finder 或 `open -a Emacs` 启动，不再需要 `launch.sh`。在个人配置中加入本文后面的 `load-path` 和 `(require 'chromel)`。

安装脚本将浏览器运行组件放入 Emacs.app，并将原应用完整备份到应用所在目录的 `.emacs-chromel-backups/` 下，输出备份路径。个人配置和浏览器 profile 保持不变。

只读预检可在 Emacs 仍运行时执行：

```sh
python3 scripts/install-app.py /Applications/Emacs.app --dry-run
```

恢复时，先退出 Emacs，再用同一个命令加 `--restore`，后跟安装时输出的完整备份应用路径。恢复也会备份当前应用，并保留原备份。

当前安装器支持未签名或 ad-hoc 签名的 Cocoa Emacs；不会把 Developer ID 签名或 hardened-runtime 应用直接降级。此类应用可继续使用独立副本方案。若 `/Applications/Emacs.app` 是 Homebrew 的软链接，脚本会显示并修改它实际指向的应用；Emacs 升级后需要重新安装。安装只复制已有构建产物，不会重新编译 Emacs 或 CEF。

### 使用独立副本

不想修改现有应用时，可以使用项目启动脚本：

```sh
./scripts/launch.sh
# 首次尝试可以不加载个人配置：
./scripts/launch.sh -Q
```

脚本在 `build/EmacsChromel.app` 中生成一个独立副本：使用现有 Emacs 的原始二进制和资源，将 CEF framework 放入副本的 `Contents/Frameworks/`，并对副本做本机 ad-hoc 签名。原来的 `/Applications/Emacs.app` 不会被修改，也不需要重新编译 Emacs。正常启动会读取相同的个人配置；`-Q` 可启动干净实例。启动脚本自动加载 `chromel.el`。

如果 Emacs 装在别处：

```sh
EMACS_APP=/path/to/Emacs.app ./scripts/launch.sh
```

如果已经有匹配版本的 CEF 二进制分发包：

```sh
CEF_ROOT=/absolute/path/to/cef_binary_... ./scripts/build.sh
```

如果找不到 Emacs 模块头文件，指定包含 `emacs-module.h` 的目录：

```sh
EMACS_INCLUDE_DIR=/path/to/emacs/include ./scripts/build.sh
```

安装到现有 Emacs.app 后，或从 `build/EmacsChromel.app` 自行启动时，把下面配置加入 Emacs。使用启动脚本时不需要重复配置。构建完成后不需要每次启动都重新构建。

```elisp
;; 替换为实际的源码目录。
(add-to-list 'load-path "/path/to/chromel")
(require 'chromel)

;; 可选；必须在首次打开网页之前设置。
;; (setq chromel-data-directory (expand-file-name "chromel/" user-emacs-directory))
;; (setq chromel-home-url "https://example.org")
```

执行 `M-x chromel` 输入地址。也可调用 `(chromel "https://example.org")`。无协议域名默认使用 HTTPS，`localhost:端口` 默认 HTTP，包含空格的输入作为搜索词。

## 在 Emacs 与网页间切换

用 `M-x chromel` 新建网页后自动选中所在窗口并聚焦网页；`Esc` 或 `C-g` 返回 Emacs，按 `i` 或点击网页重新进入网页输入。通过提示点击按钮或链接后保留 Emacs 命令焦点，可以直接再次按 `f`；普通链接或弹窗产生的前台新 buffer 也会选中并保留命令焦点；`F` 和 `M-f` 打开的链接留在后台。选择输入框、编辑区或下拉框时才进入网页输入。网页聚焦时，`C-x`、`C-c`、`C-h` 和 `M-x` 会交回 Emacs；非输入控件中的 `j` / `k` 用于滚动，其他输入交给 Chromium。页面中的复制粘贴使用 macOS 的 `s-c` / `s-v`。浏览器 buffer 内的独立 `Esc` 键按 `C-g` 处理，用于取消或返回命令状态，不再传给网页触发退出全屏；其他 buffer 的按键保持不变。

| 按键 / 命令 | 操作 |
|---|---|
| `M-x chromel` | 新建网页 buffer，并聚焦网页 |
| `o` / `O` | 输入地址或搜索词，在当前 / 新页面打开；可补全历史地址 |
| `ge` / `gE` | 编辑当前地址，在当前 / 新页面打开 |
| `r` / `C-c C-r` | 刷新 |
| `j` / `k` | 向下 / 向上滚动；支持数字前缀，例如 `C-u 3 j` |
| `gg` / `G` | 当前滚动区域的顶部 / 底部 |
| `H` / `L` | 后退 / 前进 |
| `gF` | 返回最外层页面，随后滚动外页 |
| `C-c C-p` / `C-u C-c C-p` | 返回上一层 / 最外层页面 |
| `f` / `C-c C-j` | 显示交互元素标签，点击链接、按钮或聚焦输入框 |
| `F` | 提示选择后在后台打开链接；其他控件仍在当前页操作 |
| `C-u C-c C-j` / `M-x chromel-follow-new-buffer` | 提示选择后在前台打开链接 |
| `p` / `P` | 把最新复制的文本作为地址或搜索词，在当前 / 新页面打开 |
| `t` | 新建页面，打开 `chromel-home-url`，保留 Emacs 命令焦点 |
| `J` / `K` 或 `gT` / `gt` | 按标签顺序切换到上一个 / 下一个网页，首尾循环 |
| `T` | 按标题或地址补全选择网页 buffer |
| `^` | 返回最近访问的另一个网页 buffer |
| `x` | 关闭当前网页，并切到下一个网页；最后一个关闭后返回普通 buffer |
| `X` | 恢复最近关闭的网页，放回关闭时的标签位置并选中 |
| `C-c w R` / `M-x chromel-restore-session` | 恢复上一次运行保存的会话 |
| `C-c w S` / `M-x chromel-save-session` | 立即保存当前会话 |
| `i` / `RET` / `C-c C-i` | 聚焦网页 |
| `Esc` / `C-g` | 取消当前操作、从网页返回 Emacs 命令状态 |
| `C-c w h` / `M-x chromel-history` | 搜索持久化浏览历史 |
| `C-c C-o` | 编辑并打开当前页面地址，同 `ge` |
| `C-c C-d` | 独立窗口打开 DevTools |
| `M-x chromel-stop` | 停止加载 |
| `q` | 隐藏当前网页窗口，保留 buffer |
| `C-x k` | 用 Emacs 的 buffer 关闭命令关闭网页 |
| `C-c w ,` / `M-x chromel-settings` | 打开或切回独立的 Chromium 设置窗口 |
| `C-c w P` / `M-x chromel-passwords` | 打开 Chromium 密码管理页 |
| `C-c w e` / `M-x chromel-extensions` | 管理扩展：启停、权限、选项和卸载 |
| `C-c w E` / `M-x chromel-extension-store` | 打开 Chrome Web Store 安装扩展 |

页面切换包含已加载网页和等待加载的会话标签；`gt` / `gT` 的顺序不随最近访问顺序改变。`t`、`O` 和切换页面命令在当前 Emacs 窗口显示目标页面并保留命令焦点。`o` / `O` 使用 Emacs minibuffer 和历史 URL 补全，尚未实现 Vimium 的书签混合搜索。`p` / `P` 与 Emacs 的 yank 一样，通过 `current-kill` 遵循个人剪贴板设置。

不同网页可以并排显示。同一个 buffer 同时出现在多个分屏时，只有被选中的分屏显示原生网页；其余分屏显示提示文字。切换 buffer 会隐藏对应视图，切回时恢复。页面随所在 Emacs frame 移动，不使用外部置顶窗口跟随位置。

`j` / `k` 在 Emacs 命令状态和网页聚焦时都可滚动，每次默认滚动 60 CSS 像素，可通过 `chromel-scroll-step` 调整。命令交给 CEF 当前聚焦的 frame，支持同域、跨域和多层嵌套 iframe：点击内页后直接按 `j` / `k`，无需先按 `C-g`。网页中的输入框、可编辑区域和下拉框保留正常字母输入；数字前缀在 Emacs 命令状态下使用。按 `C-c C-p`（`chromel-focus-parent-frame`）将焦点移到上一层页面；`C-u C-c C-p` 直接返回最外层。返回时取消原 frame 的滚动动画并保留 Emacs 命令焦点，不用再按 `C-g`。点击外页空白处也可切回外页。

滚动优先作用于最近操作的区域或当前弹层，到达边界后向同一文档内的外层区域继续滚动。暂不跨 iframe 边界向父文档传递滚动。

点按使用约 140 毫秒的平滑动画，由 `chromel-scroll-duration` 控制；分开的多次点按累计距离。长按使用同一个逐帧动画，短暂过渡后按 `chromel-scroll-speed` 持续移动，默认 900 CSS 像素/秒，不再依靠系统重复按键追加距离。长按松开即停；很短的点按仍会完成一次步长。反向按键取消旧方向的剩余距离；切换 buffer、窗口失去焦点、滚轮、触摸或点击会停止滚动。

可以分别调整点按距离和长按速度：

```elisp
(setq chromel-scroll-step 60
      chromel-scroll-speed 900
      chromel-scroll-duration 140)
```

`chromel-scroll-duration` 设为 `0` 或启用系统“减少动态效果”时，使用即时滚动。数字前缀、程序调用和键盘宏按指定距离滚动。

Meow 用户：`chromel-mode` 默认使用 **motion** 状态，浏览器键位定义在 `chromel-mode-map` 中，`SPC` 继续进入 Meow keypad。只将 `meow-next` / `meow-prev` 局部重映射为网页滚动，以适配常见的 motion `j` / `k` 配置；不修改 Meow 的共享键位或其他 buffer。支持先加载 Meow 或先加载 chromel；若你在 `meow-mode-state-list` 明确设置了 `chromel-mode` 的状态，会保留该设置。个人额外定义的 motion 按键仍优先于 major mode。

## Chromium 设置

执行 `M-x chromel-settings`，或在网页 buffer 中按 `C-c w ,`，打开真实的 `chrome://settings/` 页面。用 `o` / `O` 输入该地址也会打开设置窗口；支持 `chrome://settings/fonts`、`chrome://settings/languages` 等子页面。普通网页仍嵌入 Emacs。

设置在独立窗口中打开，与嵌入网页共享本插件的 profile，不使用你日常 Google Chrome 的个人资料。重复执行 `chromel-settings` 会切回已有窗口并保留当前子页面；显式输入设置地址则导航到指定页面。设置窗口不计入 Emacs 标签、浏览历史或会话恢复；可以独立关闭，退出 Emacs 时也会关闭并保存配置。

设置窗口使用 Chromium 自己的鼠标和快捷键，不使用网页 buffer 的 Vimium / Meow 键位。

Chromium 的启动页、搜索引擎等选项不会替代 `chromel-home-url`、Emacs 搜索入口和会话管理。

## 密码管理与自动填充

执行 `M-x chromel-passwords`，或在网页 buffer 中按 `C-c w P`，打开真实的 `chrome://password-manager/`。也可以通过 `o` / `O` 输入该地址。它与设置页复用同一个独立窗口，与内嵌网页共享本插件的 profile，不读取日常 Google Chrome 的密码库。

1. 在密码管理页点击添加密码，填写网站、用户名和密码。
2. 返回 Emacs，打开或重新加载该网站的登录页。
3. 点击登录输入框，Chromium 负责识别和填充；密码管理窗口关闭后仍可使用。

凭据由 Chromium 管理并使用系统钥匙串，不写入 Elisp 历史或会话文件。

目前支持在管理页手动添加凭据后自动填充。首次登录后的保存/更新提示、多账号选择和复杂网站表单的兼容性尚未确认；不支持 Google 账号同步。

## 扩展管理与 Chrome Web Store

1. 执行 `M-x chromel-extension-store`（网页 buffer 中为 `C-c w E`）。
2. 在官方商店找到扩展，点击 **Add to Chrome**，阅读权限提示后确认安装。
3. 返回 Emacs，重新加载需要使用扩展的页面。
4. 执行 `M-x chromel-extensions`（`C-c w e`）管理已安装扩展：启用/禁用、网站权限、扩展选项、快捷键和卸载。

`chrome://extensions/`、其子页面及 `https://chromewebstore.google.com/` 都自动进入共享的 Chrome-style 管理窗口。从内嵌网页导航到商店也会转交，并保留原 buffer。管理窗口包含 Chromium 原生工具栏，可后退、查看地址和访问扩展菜单。它与设置/密码管理页复用窗口和 profile，不使用日常 Google Chrome 的扩展目录。

安装、权限确认及扩展更新由 Chromium 管理。扩展和状态保存在 `chromel-data-directory` 对应的 profile 中。

**安装成功不代表所有扩展功能都兼容。** 工具栏弹窗作用于独立 Chrome 窗口，不会自动获得当前 Emacs buffer 的标签上下文；依赖 `activeTab`、Chrome 标签栏、侧栏、Google 登录或桌面应用通信的扩展仍需单独适配。1Password 的桌面联动尚未实现。CEF 官方关于 [Alloy 与扩展界面的说明](https://github.com/chromiumembedded/cef/issues/3859)也区分了共享 request context 的能力与 Chrome UI 能力。

## 用键盘操作链接和控件

网页聚焦时按 `C-c C-j`，或先按 `C-g` 回到 Emacs 再按 `f`。可见的链接、按钮和表单控件旁会出现黄色字母标签，例如 `a`、`s`、`aa`。输入完整标签立即执行操作，不需要回车。输入过程中不匹配的标签会隐藏；退格可以重新选择，`C-g` 或 Escape 取消。

- 链接、按钮、复选框、单选框、折叠区标题：触发 Chromium 的鼠标点击，保留页面的事件处理、`preventDefault`、表单默认动作和弹窗行为。
- 输入框、文本区域、可编辑内容：聚焦后可以直接输入；单行文本框初始光标在开头时移到末尾，已有光标位置尽量保留。
- 下拉框：聚焦后用空格、方向键和回车操作。
- `F`：普通链接按新标签方式在后台 buffer 打开，当前页面保持选中；按钮和表单仍在当前页操作。需要前台打开时使用 `C-u C-c C-j`。

标签默认使用 `asdfghjklqwertyuiopzxcvbnm`；可通过 `chromel-hint-alphabet` 自定义至少两个不重复的小写字母。若滚动或尺寸变化使标签位置失效，会清除提示，需要重新调用命令。

支持主文档和开放 shadow DOM 中的标准控件、关联隐藏表单控件的 label、常用 ARIA 交互角色，以及带 `onclick`、可键盘聚焦或显示手形光标的自定义控件。隐藏、被遮挡、禁用、inert 和屏幕外的元素会跳过，最多标注 1000 个。选择后会重新检查元素位置与可用状态，模态对话框内也能显示标签。

`f` / `F` 提示暂不进入 iframe 或关闭的 shadow DOM（`j` / `k` 滚动支持聚焦的 iframe）；没有语义标记、焦点或手形光标的自定义事件控件可能无法识别。

## 查找页面内容、快速滚动和处理链接

按 `Esc` 返回 Emacs 命令状态后，可用下面的简短按键。Meow motion 下可直接使用这些键；另外保留 `C-c w` 命令入口，网页正聚焦时可直接从 `C-c w` 开始。

| 操作 | 简短按键 | 通用入口 / 命令 |
|---|---|---|
| 页内搜索 | `/` | `C-c w s` / `chromel-find` |
| 下一个 / 上一个匹配 | `n` / `N` | `C-c w n` / `C-c w p` |
| 清除搜索高亮 | — | `C-c w c` / `chromel-find-clear` |
| 向下 / 向上半页 | `d` / `u` | `C-c w d` / `C-c w u` |
| 滚动区域顶部 / 底部 | `gg` / `G`（也保留 `M-<` / `M->`） | `C-c w <` / `C-c w >` |
| 复制当前地址 | `yy` | `C-c w y` / `chromel-copy-url` |
| 用提示标签复制链接 | `yf` | `C-c w f` / `chromel-copy-link` |
| 连续在后台打开链接 | `M-f` | `C-c w m` / `chromel-follow-multiple` |

搜索在 minibuffer 输入文字，按回车后定位并高亮，mode line 显示当前匹配序号和总数。搜索使用 Chromium 原生接口，支持跨域 iframe 内的可搜索文本；当前为不区分大小写的字面文本搜索，不提供正则表达式。`n` / `N` 循环查找，查询和匹配状态按 buffer 保存。在输入查询时按 `Esc` / `C-g` 会取消并清除高亮；已经完成搜索后用 `C-c w c` 清除。清除后仍可用 `n` / `N` 再次搜索上次文字。

半页距离取当前滚动区域高度的一半：页面、内嵌页和弹层中的面板分别按自己的高度计算。`C-u 3 d` 向下滚动三个半页。顶部/底部命令同样作用于当前区域，在区域已到顶部/底部时不跳到外页。刷新使用 `r`，编辑地址使用 `ge`，历史使用 `C-c w h`。

`yy` 和 `yf` 使用 `kill-new`，放入 Emacs kill-ring，并按 Emacs 的剪贴板设置同步。`yf` 只标注可见链接，选择时重新读取并校验地址，不触发网站点击事件，也不会打开网页。

连续打开模式只标注普通 HTTP、HTTPS、file 链接。每选中一个，发送真实的修饰鼠标点击，新页面在后台 buffer 打开，原页面保持选中，原来的标签继续可用。`Esc` / `C-g` 结束并清除标签；随后用 Emacs buffer 切换命令访问新页面。网站的点击处理仍会执行，也可以通过 `preventDefault` 阻止打开。页面若发生导致标签位置变化的滚动或重排，需要重新调用命令。`F` 只打开一次并结束提示，`M-f` 则保留提示以连续打开。

复制及连续打开的提示范围沿用现有提示：主文档和开放 shadow DOM，暂不进入 iframe。后台 buffer 与前台 buffer 共享同一 profile。`F` / `M-f` 打开的网页立即在后台加载；会话恢复出的后台标签则等选中时再创建浏览器。已加载页面尚不自动休眠或卸载。

## 找回关闭的页面和恢复会话

按 `X` 恢复最近关闭的网页，连续按可逐个找回。用 `x`、`C-x k` 或切换 major mode 关闭的网页都会记录，默认保留最近 30 个。恢复会尽量插入关闭时的位置并保留 Emacs 命令焦点。最后一个网页关闭后，在其他 buffer 执行 `M-x chromel-reopen-closed-tab` 即可。恢复失败时保留原记录，可以重试。

打开、关闭、导航、标题或选中项变化后，会话会在约 1 秒内自动保存；正常退出时再保存一次，然后等待原生浏览器完成关闭。重启后执行 `M-x chromel-restore-session`，或在网页中按 `C-c w R`：

- 恢复保存的地址、标题、标签顺序和选中项；关闭记录也会保留，重启后仍可用 `X`。
- 最初只为保存的选中页面创建 CEF 浏览器。其他标签可以在 `T` 或普通 Emacs buffer 列表中找到，首次选中时才加载；`J/K`、`gt/gT` 和普通 buffer 切换都支持。
- 保留当前已打开的页面，恢复出的标签追加在后面。同一次 Emacs 运行中只允许恢复这份会话一次，避免重复打开。
- 只加载插件而没有打开或恢复网页，不会把上次会话覆盖为空。即使先打开了新页面，上次会话仍保留在内存中供恢复；首次保存新会话时也会把上一份写入 `session.previous.json`。
- 会话文件用 UTF-8 JSON 原子替换，权限为 `0600`；读取失败或版本不支持时会提示并停止覆盖该文件，正常浏览仍可使用。

这恢复的是页面地址，不保存网页内容、表单输入、滚动位置或每页的前进后退栈。页面会重新请求网站，登录状态由现有 CEF profile 决定。突然崩溃时可能丢失尚未写出的变动；通常保存间隔约一秒，Emacs 长时间忙碌时会延后。手动关闭全部页面会保存空的打开列表，但仍可通过 `X` 的关闭记录找回。

```elisp
;; 可选：调整关闭记录数，或关闭自动会话保存。
(setq chromel-closed-tab-limit 30)
;; (setq chromel-session-auto-save nil)
```

`C-c w S` 可随时立即保存。自动保存关闭时，该命令仍可手动保存。

## 数据和能力边界

默认数据在 `~/.emacs.d/chromel/`（实际相对 `user-emacs-directory`）：

```text
chromel/
├── history.json          # 插件维护的历史；默认最多 1000 个不同 URL
├── session.json          # 当前会话：标签、选中项和关闭记录
├── session.previous.json # 本次运行首次保存前的上一份会话备份
└── profile/
    ├── cef.log           # 原生错误日志
    └── Default/          # CEF Cookie、站点存储与缓存
```

这个 profile 独立于系统 Chrome。修改 `chromel-data-directory` 后需要重启 Emacs；不要指向现有 Chrome profile，也不要让两个 Emacs 实例同时使用同一个 profile。CEF 初始化后不能在同一进程中卸载、重新初始化；更新 `.dylib` 后也需要重启 Emacs。首次使用系统钥匙串加密时，macOS 可能显示授权对话框。

- Cookie 和站点存储使用磁盘 profile；网站仍可按自身规则让登录失效。
- 历史由 Elisp 从成功加载事件记录，使用 JSON 和原子替换保存，不依赖 `chrome://history`。
- 点击打开新窗口的链接会转成新 Emacs buffer。第一版不保留 `window.opener` 关系，依赖脚本弹窗通信的登录流程可能不兼容。
- 页面关闭会强制完成，暂不提供 `beforeunload` 的“未保存内容”确认。
- CEF helper 保持 Chromium 沙箱开启，没有添加 `--no-sandbox` 或绕过证书校验的参数。
- 目前支持 NS/Cocoa Emacs，不支持终端 Emacs、Linux、GNUstep 或 emacs-mac port。

## 许可证

本项目代码采用 GPL-3.0-or-later，见 [LICENSE](LICENSE)。CEF 及 Chromium 组件遵循各自许可证；相关许可证及第三方声明保留在下载的分发包中。
