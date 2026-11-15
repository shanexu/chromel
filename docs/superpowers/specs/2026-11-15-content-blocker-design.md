# 内容拦截器（uBOL 规则）设计

日期：2026-11-15
状态：已批准（2026-11-15）
分支：`topic/blocker`

## 意图与为什么

用户日常用 uBlock Origin Lite，方式就是订阅官方标准列表（`ublock-filters`、`easylist`、
`easyprivacy`），不写自定义规则。chrome 里的 uBOL 在 CEF 里跑不起来：它依赖
`declarativeNetRequest`（`//chrome` 层）和 MV3 service worker，两者 CEF 都没有；
`webRequest` 阻塞式 API 也没有。所以目标不是"装插件"，而是**把同样这几套列表的拦截效果
做进 Chromel 自己**，默认开启，行为尽量贴近"装了 uBOL 没动过设置"。

真正的成本在破站：订阅规则一定会拦坏某些页面（登录跳转、视频播放器）。uBOL 的解法是
"这个站点关掉过滤"。用户已明确选择：一条命令关掉当前站点、并记住它。

## 目标

1. 加载标准列表编译出的规则，默认生效（仓库自带编译好的快照），无需逐条配置。
2. 拦截发生在请求离开浏览器进程之前（`OnBeforeResourceLoad`），页面不会看到被拦请求。
3. `allow` 规则优先于拦截（uBOL 里 allow 的优先级更高）。
4. 按站点关闭过滤：一条命令，作用于当前页面所属站点，记住并持久化。
5. 可观测：至少能看到"加载了多少条规则、本次会话拦了多少个请求"。
6. 规则文件缺失或损坏时**安全降级**（不拦、给出明确消息），不能拖垮浏览。

## 非目标（第一版不做）

- 元素隐藏（cosmetic / `##` 选择器）：会逼着往渲染进程注入 CSS，风险和第一步不是一个量级。
- scriptlet（反广告墙脚本）、`redirect`、`modifyHeaders`/`csp`、`$removeparam`。
- 规则编辑器、元素选择器、"为什么拦了这个"的逐条查询 UI。
- 规则自动更新/定时拉取。
- 按标签页或按容器区分的策略。

## 反目标（技术上能跑，但算失败）

- 每请求耗时超过 100 µs，或整页加载明显变慢。
- 为了拦截而阻塞主线程、让 Emacs 卡顿。
- 静默失效：规则坏了却什么都不说，用户以为在拦。
- 因为过度拦截让常见站点（登录、视频）不可用，且没有一键恢复。

## 约束（已核实）

- CEF 156 没有 `declarativeNetRequest`；`OnBeforeResourceLoad` 是唯一的拦截点，
  运行在浏览器进程 UI 线程，**必须快**。
- 可拿到的判定信息只有：请求 URL、`GetResourceType()`、frame 的 URL（发起方近似）、
  `GetFirstPartyForCookies()`、请求头。拿不到 DOM、拿不到响应体、改不了响应头。
- uBOL 规则是 DNR JSON，字段与我们能拿到的信息基本对得上（这是整个方案成立的前提）。
- 规则规模（实测三套列表）：18,514 条 DNR → 展开为 117,141 条可匹配规则、3.7 MB 文本；
  其中 97,598 条只按域名（含 5,251 条按发起站点），8,804 条域名+路径，4,961 条全局子串，
  570 条正则，6,439 条 allow；934 条动作类型（redirect/改头）与 378 条模式必须丢弃。
- 阻断类型分布：`domainType` 为空 108,760 / 第三方 6,710 / 第一方 1,671；
  限定资源类型的 11,003 条。

## 方案（已选定）

用户已选 **A：自建 C++ 匹配器**。备选 B 是"本地过滤代理 + PAC 指过去"，
它不用改 C 代码、能热更新，但 HTTPS 只看得到域名看不到路径，精度从 117k 条掉到域名级，
还要多一个常驻进程和一跳延迟，因此否决。

分两步，第一步先证明体验和开销：

### 第一步（本设计覆盖的范围）

- **编译**：`scripts/ubol-to-blocklist.py` 读 uBOL DNR JSON，产出带版本头的行式文件。
  第一版**只保留域名规则**（`h=`/`i=` 两种匹配子），其余计入统计并丢弃。
- **加载**：`native/blocklist.{h,mm}` 在 CEF 初始化前读文件，建立
  `unordered_map<string, vector<Rule>>` 按域名后缀索引；allow 与 block 分开存。
- **匹配**：对请求 host 从右往左逐级查后缀（`a.b.c` → `a.b.c`, `b.c`, `c`，最多 4 次），
  命中 allow 立即放行；否则命中 block 且资源类型匹配则 `RV_CANCEL`。
- **资源类型**：`GetResourceType()` 转成位掩码，`mask == 0` 表示所有类型。
- **按站点关闭**：例外按 **host 后缀** 匹配（存 `example.com` 就覆盖它的子域），
  比对对象是顶层文档的 host（取 `browser->GetMainFrame()->GetURL()`）。命中例外则该页所有
  请求都不拦。Elisp 负责存储与命令，native 只负责查询。
- **粒度**：`chromel-blocker-toggle-site` 默认只针对当前精确主机名；`C-u` 前缀升到父域
  （取末两段）。若末两段命中内置的公共后缀小表（`co.uk`、`com.cn`、`github.io` 等，约几十条），
  拒绝该操作并提示，避免一键关掉整个 `co.uk`。
- **可观测**：`info()` 增加 `Blocklist: N rules, M blocked`；
  `M-x chromel-blocker-status` 回显规则数与拦截计数。

### 第二步（本设计只留接口，不实现）

路径前缀、子串 token 索引、正则兜底、`domainType` 的第三方判定（含近似 PSL）、
元素隐藏的 CSS 注入。第一步的行格式与 API 预留这些字段，避免二次改格式。

## 规则来源与更新（已定）

- 快照与转换器一起进仓库：`data/blocklist.txt` 由固定版本的 uBOL 规则集编译而来，
  文件头记录 uBOL 的 commit、生成时间与三套列表的名字。
- 重新生成的步骤写进 `data/README.md`：下载 uBOL 三个 ruleset JSON →
  `python3 scripts/ubol-to-blocklist.py … -o data/blocklist.txt`。
- 许可证：uBOL 是 GPL-3.0；EasyList/EasyPrivacy 是 CC BY-SA。列表数据打包进本仓库时
  在 `data/blocklist.LICENSE` 里写明来源与许可，README 指向它。

## 设计细节（我的判断，可推翻）

- **文件格式**：沿用草稿的行格式，行首 `#` 为注释；每行
  `action \t types-hex \t flags \t spec`，`spec` 用 `;` 连接 `h=`/`i=`/`p=`/`u=`/`r=`。
  第一版只用 `h=`/`i=`，其余字段留给第二步。
- **默认值**：`chromel-blocklist-file` 默认为仓库内的 `data/blocklist.txt`（按
  `chromel--directory` 解析）。文件不存在时禁用拦截并 `message` 说明，不报错。
- **例外存储**：`chromel-blocker.json` 放在 `chromel-data-directory`，原子写（临时文件 + rename，
  模式 600），与 session 的写法一致；内存里用 hash 表做后缀查询。
- **命令**：`M-x chromel-blocker-toggle-site` 对当前页面站点开关并回显结果（含它覆盖哪些主机）；
  `chromel-blocker-status` 显示规则数、命中数、当前站点是否被排除。
- **资源类型掩码**：与 `RESOURCE_TYPES` 顺序一致（main_frame, sub_frame, stylesheet, script,
  image, font, object, xmlhttprequest, ping, media, websocket, other）。
- **失败处理**：文件不存在/解析失败 → 记录原因、禁用拦截、`message` 提示；
  单条规则非法 → 跳过并计数，不整体失败。
- **线程**：加载在 `initialize()`（UI 线程、CEF 启动前）完成；匹配只在 UI 线程读只读结构，
  不加锁。
- **性能验证**：在 `chromel-smoke` 加一个 `--blocklist-bench <file> <n>`，用合成 URL 测
  µs/请求；第一步的验收门槛是 **< 20 µs/请求**（只有域名表时应该远低于此）。

## 已知不精确（第一版接受，写进文档与 CHANGELOG）

- 忽略 `domainType`（第三方/第一方）标记：8,381 条规则会在"本不该拦"的场景生效，
  可能过度拦截同站点自用的广告域名。
- 按站点关闭用顶层文档 host 近似，iframe 里的第三方内容跟随顶层站点。
- 只有域名规则，路径/子串/正则规则暂不生效（预计覆盖 uBOL 网络拦截的 ~80%）。

## 风险

| 风险 | 应对 |
|---|---|
| 长尾站点被拦坏，用户不知道是哪条 | 第一版给"按站点关掉"；逐条查询留到第二步 |
| 规则集随 uBOL 更新而演化，DNR 字段变多 | 转换器对未知动作/字段只计数不失败，统计会立刻暴露漂移 |
| 启动解析 3.7 MB 拖慢首次打开 | 只解析域名行，实测 < 100 ms；必要时改成二进制索引 |
| 拦截太狠导致用户直接关掉功能 | 默认只上三套标准列表，不叠加 annoyances/urlhaus 等激进列表 |

## 已确认的选择

1. 默认名单：`ublock-filters` + `easylist` + `easyprivacy` 三套，编译成仓库内的快照，默认生效。
2. 规则文件位置：`data/blocklist.txt`（随仓库），可用 `chromel-blocklist-file` 覆盖。
3. 按站点粒度：默认精确主机，`C-u` 升父域；父域命中公共后缀小表时拒绝。

## 交付物

- `scripts/ubol-to-blocklist.py`（草稿已存在，按本设计重写第一版范围）
- `data/blocklist.txt`（固定版本快照）、`data/blocklist.LICENSE`、`data/README.md`（再生成步骤）
- `native/blocklist.{h,mm}`、`native/chromel_core.mm` 的 `OnBeforeResourceLoad` 接入、
  `native/module.mm` 的加载/查询入口、`chromel.el` 的 defcustom/命令/事件
- ERT：规则解析、后缀匹配、allow 优先、例外生效
- GUI：一个 fixture 页面引用被拦域名，断言"请求没发出、计数器 +1"
- 文档：README 一节、`docs/architecture.md` 新增小节、CHANGELOG、TODO 标记
