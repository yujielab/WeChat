# Cuven · Cloudflare 自建即时通讯

一个完全跑在 **Cloudflare** 上的自建即时通讯 App：注册账号、加好友、单聊和群聊、
发图片和手绘、语音 / 视频通话。没有第三方服务，消息和媒体都存在你自己的
Cloudflare 账号里。界面参考 iOS“信息”，并借鉴 Benji Taylor（Family / Honk /
drawesome）的设计与动效，专门为 **iPhone Duo** 的外屏（折叠）与内屏（展开）打磨。

界面沿用 Cuven Transfer / Worker Studio 的纸白与近黑设计语言：共享选中胶囊、
触下反馈与弹簧回弹、浮动输入框、可跟手关闭的纸感弹层。登录、消息、手绘和设置
使用同一套间距与材料层级，支持深色、减少动态效果及窄窗口。

融入 Magnetic Dropzone、Input OTP 和 Dropdown Menu 的交互细节：图片可拖入或粘贴，
预览后确认发送；邀请码保留完整原生输入，辅以分段焦点轨道；菜单高亮跟随鼠标和键盘。

双屏界面按 Apple《[针对 iPhone Duo 设计](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)》重新设计：

- **一条横向的栏带**：边栏 | 列表 | 对话 | 详情 四栏排成一条，屏幕是在这条栏带上滑动的窗口——合上时看一栏，
  打开时看相邻两栏（等宽）。前进时窗口向右滑一栏，“返回”、从左缘轻扫或浏览器后退时向左滑；轻扫 1:1 跟手，
  松手时按速度决定完成还是弹回。折叠 / 展开时，正在使用的那一栏留在屏幕上：例如打开时看着对话与详情，
  合上后看到的是详情；打开时在对话里输入，合上后仍是对话。
  - **边栏**：头像与名字（打开设置）、全部 / 未读 / 私聊 / 群聊（只有未读带数字），独占屏幕时还有搜索与新聊天。
  - **详情**：对话的“聊天信息”（免打扰、置顶、成员、退出 / 删除）和画板都在对话旁边这一栏打开，
    边看对话边画；合上时“关闭”变为“返回”。
  - 与边栏并排时列表不再重复筛选与品牌，对话在视野外时新消息重新计为未读。
- **少用说明文字**：让布局自己说明——去掉副标题、分组说明、重复的占位提示和功能介绍；详情栏不加标题（顶部的头像与名字已经说明是谁），
  私聊标题下只在对方在线时显示状态。
- **底部胶囊栏**：每一栏的控制都在底部一条悬浮的玻璃胶囊栏里，单手可及，56pt 高：单个项目是圆形，成组的是胶囊，
  中间是搜索框或输入框。列表：“返回边栏”（与对话并排时加上筛选）在前，搜索框居中，“新聊天”在末端；
  对话：“返回”在输入框前，输入框后只有一个按钮——空着时是“+”（展开照片与手绘），有字时原位变成“发送”，通话与聊天信息在标题右侧；边栏：搜索与新聊天；详情：“返回 / 关闭”；
  画板：“关闭”、撤销与清空、“发送”。栏随键盘上移，始终在安全区内——包括系统在右缘留出的状态栏一列，
  以及 iOS 27.2 把这一列留在页面之外的情况。真机内屏为 951×669pt。
- **高频轻、低频才完整**：发送、切换会话、点工具栏这些每天几百次的操作只有轻量反馈——消息 170ms 出现、
  切换 160ms 淡入，都没有缩放、模糊或回弹，按钮只有按压；完整的形变留给有明确来源、较少发生的操作（“+”面板、
  图片查看器、从头像展开的设置、通话记录组）。展开内屏用来增加上下文（列表与对话并排），而不是放大界面：
  字号不变，正文每行约 28 字以内。
- **动效有来处、可反向**：按下即时轻压到 0.98 并微调明度，松手从当前位置回弹；“+”面板从按钮本身长出、“+”转成“×”，
  半途再点从当前位置收回；输入框按行向上生长，胶囊过渡为圆角矩形（最多 5 行后内部滚动）；照片从预览衔接进新消息、
  从气泡展开到查看器再回到原处；展开时设置从头像处展开；连续未接通话折叠成一条，向上展开每一次。减少动态时即时变化。
- **状态真实**：最新消息与“已发送”始终在底部栏之上；失败的消息旁出现“重试”，原位变为“发送中”，成功后收起，
  同一条消息不会重复发送；对方的已读不会盖掉“未发送”；通话记录按各自视角说明结果（对方未接听、已取消、未接来电……），
  列表摘要与之一致。
- **溢出**：空间不足时，项目按优先级收进唯一的“更多”（省略号只用于溢出，位于标题行末端），“返回”从不溢出，
  带角标的项目保留得最久；焦点跟随项目进出溢出菜单。每个项目都有符号与标题，标题用于溢出菜单、辅助功能与提示。
- **分栏浏览**：两栏的底部栏在同一条基线上；部分折叠时两栏以折叠区为界，
  内容与弹层都不跨越折叠区（通过浏览器的视口分段检测）。像笔记本一样折起时，消息在折痕上方，输入在下方。
- **弹层**：表单的标题在前、“关闭”在后；内屏上放在前置栏一侧的表单标题居中。照片查看器与通话占满宽度，控制在底部。
- 双方头像标记消息分组，连续照片合为照片叠；消息可以回应（长按菜单或双击 ❤️），私聊“已读”重开后仍保留。
  折叠与展开之间以视图过渡衔接，布局变化保留草稿、选区与阅读位置；减少动态效果时直接切换。

<img src="docs/screenshots/11-auth-desktop.png" width="880" alt="Cuven 桌面登录界面">

| 合上：对话 | 打开：列表 + 对话 | 滑一栏：对话 + 详情 | 合上：详情 |
| --- | --- | --- | --- |
| <img src="docs/screenshots/24-strip-closed-chat.png" width="160" alt="合上时只显示对话一栏"> | <img src="docs/screenshots/25-strip-open-list-chat.png" width="300" alt="打开时列表与对话两栏等宽"> | <img src="docs/screenshots/26-strip-open-chat-details.png" width="300" alt="窗口滑到对话与聊天信息"> | <img src="docs/screenshots/27-strip-closed-details.png" width="160" alt="合上后留在详情，返回在列顶"> |

| 打开：边栏 + 列表 |
| --- |
| <img src="docs/screenshots/28-strip-unfold-from-sidebar.png" width="420" alt="展开时窗口留给列表与对话，设置在列表标题末端"> |

| 折叠（外屏 466×678） | 展开（内屏 890×626） |
| --- | --- |
| <img src="docs/screenshots/15-duo-folded.png" width="240" alt="底部栏：返回、输入框与其后的“+ / 发送”；通话与信息在标题右侧"> | <img src="docs/screenshots/16-duo-unfolded.png" width="420" alt="列表与对话两栏等宽，底部栏在同一基线"> |
| <img src="docs/screenshots/05-drawboard.png" width="240"> | <img src="docs/screenshots/18-duo-dark.png" width="420" alt="双屏布局深色模式"> |
| <img src="docs/screenshots/03-live-typing.png" width="240"> | <img src="docs/screenshots/17-duo-gallery.png" width="420" alt="照片组逐张浏览"> |
| <img src="docs/screenshots/07-settings.png" width="240"> | <img src="docs/screenshots/01-auth.png" width="240"> |

| 非零侧边 / 底部安全区 | 键盘弹出：底部栏随键盘上移 | 外屏横放 | iOS 27.2：系统列在页面外 |
| --- | --- | --- | --- |
| <img src="docs/screenshots/19-safe-layout.png" width="220" alt="安全区内的底部栏"> | <img src="docs/screenshots/21-safe-keyboard.png" width="220" alt="键盘上方的底部栏"> | <img src="docs/screenshots/22-outer-landscape.png" width="320" alt="横放时的底部栏"> | <img src="docs/screenshots/29-outer-page.png" width="200" alt="376pt 页面上的底部栏"> |

| 部分折叠（书本）：两栏以折叠区为界 | 部分折叠（笔记本）：消息在上，输入在下 |
| --- | --- |
| <img src="docs/screenshots/22-duo-sheet-side.png" width="420" alt="新聊天表单留在列表一侧，不跨越折叠区"> | <img src="docs/screenshots/23-duo-laptop.png" width="300" alt="折痕上方是消息，下方是输入框"> |

| 图片发送前预览 | 发送中 |
| --- | --- |
| <img src="docs/screenshots/12-attachment-preview.png" width="240" alt="带点阵拖放区的图片预览"> | <img src="docs/screenshots/13-image-sending.png" width="440" alt="图片发送中"> |

> 截图来自本地 `wrangler dev`，账号和消息都是演示数据。

## 功能

- **账号**：用户名 + 密码注册 / 登录（PBKDF2 哈希），可选邀请码 `SIGNUP_CODE`
- **实时聊天**：单聊、群聊；消息经 WebSocket 实时送达，掉线自动重连补收
- **在线状态**与**已读回执**（私聊重新打开后仍显示“已读”）；**“正在输入”实时预览**（Honk 式：对方能看到你正在打的字）
- **回应**：长按消息从 ❤️ 😂 👍 😮 😢 🙏 中选一个，或双击送出 ❤️；每人每条消息一个，实时同步
- **图片**（手机端先压缩再传）与**手绘画板**（速度自适应笔触、调色板、撤销，发出为“手绘”消息）
- **表情**：Telegram 表情包（静态、视频、动画三种），经自己的 Worker 取来存进 R2；每人在表情面板里从预设的表情包名称表中添加 / 移除；动画表情只在屏幕上时播放
- **语音 / 视频通话**：基于 **Cloudflare Realtime（SFU）**，一对一与群组都支持，自带 TURN 穿透
- **联系人**：按用户名查找、互相添加；发起单聊 / 新建群聊、群成员管理
- **通知**：新消息与来电用 **Declarative Web Push**（Safari 18.4 起由系统直接显示，应用退出或在后台也能收到；其他浏览器经 Service Worker 显示同一条消息），带应用角标；需加到主屏幕，推送密钥自动生成
- **外观**：默认白色浅色界面，可切换深色 / 跟随系统；降低透明度、减少动态效果、触感反馈
- **iPhone Duo**：每栏底部的胶囊栏与优先级溢出、外屏单栏 / 内屏分栏、折叠区与相机避让、弹层按所在栏放置

## 架构

```
iPhone (PWA)  ──HTTPS / WebSocket──▶  Worker（瘦代理）  ──▶  Hub Durable Object "main"
  静态页面 public/                     /api /auth /rtc        · 账号 / 联系人 / 房间 / 消息（SQLite）
  Service Worker：离线壳 + 推送          转发到 Hub            · 可休眠 WebSocket 实时收发 + 在线状态
                                                             · 媒体校验后读写 R2
                        WebRTC 媒体 ◀──▶ Cloudflare Realtime  · 通话信令中转 + /rtc 代理（App Secret 只在服务端）
                        离线成员 ◀────── Declarative Web Push（VAPID）：新消息、来电、未接来电
```

- **Worker（`src/index.js`）**：只做转发与同源校验，所有状态都在一个 Durable Object 里。
- **Hub（`src/hub.js`）**：账号、联系人、房间、消息、在线状态、WebSocket 广播、通话信令，
  全部集中在一个 DO，SQLite 强一致，推理简单。
- **数据层（`src/store.js`）**：users / contacts / rooms / room_members / messages / push_subs。
- **媒体（`src/media.js`）**：上传按会话成员与大小校验后流式写入 **R2**；下载带 sandbox CSP + nosniff，
  按会话成员鉴权。
- **通话（`src/call.js`）**：信令走 WebSocket；媒体经 `/rtc/*` 代理到 **Cloudflare Realtime SFU**，
  App Secret 不下发浏览器；TURN 凭证由 Realtime TURN key 下发。响铃中的通话存在 Durable Object 里：
  对方应用没开、或打开了却没回应“正在响铃”时，改用通知呼叫；对方转到后台不会挂断，点通知回来会继续响铃。
  主叫看到对方是“响铃中”“已通过通知提醒”还是“没有打开应用，也没有开启通知”。
- **账号加密（`src/auth.js`）**：PBKDF2-HMAC-SHA256（100k 轮，Workers WebCrypto 的迭代上限）哈希密码；HMAC 签名会话令牌，
  携带 epoch，可“全端退出”。

## 部署

需要一个 Cloudflare 账号。Durable Objects 的 SQLite 存储需要 Workers 付费版（$5/月）。

```bash
npm install

# 1) 创建 R2 存储桶（媒体文件）
npx wrangler r2 bucket create cf-messenger-media

# 2) 可选：设置邀请码，避免任何人都能注册
npx wrangler secret put SIGNUP_CODE

# 3) 部署
npx wrangler deploy
```

打开部署后的地址，点“创建账号”注册第一个用户即可。把地址发给朋友，各自注册、互相添加。

### 从旧版升级 / 使用 Workers Builds

- 使用 Node.js 22 或更新版本（Wrangler 4.152.0 要求 Node.js ≥22，仓库的 `.node-version` 已指定 22）。
- 当前连接的 Cloudflare Worker 是 `wechatduo`，与 `wrangler.jsonc` 的 `name` 保持一致。
  如果部署到另一个 Worker，先修改 `name`；设置 secret 时也应使用同一个配置。
- `routes` 保留现有自定义域名 `wechat.cuven.us`，避免部署时清除仪表盘上的域名绑定。
  自建到其他账号时，应改成自己的域名，或移除这项配置。
- Workers Builds 的根目录使用仓库根目录，构建命令留空（静态文件无需编译），部署命令使用
  `npm run deploy`。首次部署前，在同一个 Cloudflare 账号创建 `cf-messenger-media` R2 桶。
- 拉取请求的构建运行 `npx wrangler preview`，使用 `wrangler.jsonc` 里的 `previews` 配置：每个预览有独立的 Hub
  （账号、消息互不影响生产），媒体写入单独的桶。在同一账号创建一次：
  `npx wrangler r2 bucket create cf-messenger-media-preview`。预览不继承生产 secret，需要时用
  `npx wrangler preview secret` 设置。
- 旧版已执行 `v1`（`WeChatSession`），升级由新增的 `v2` 创建 `Hub`。
  保留历史迁移和旧类导出，不要把 `v1` 改成 `Hub`，也不要删除旧 namespace。
  旧微信存储保留但不再使用；Cuven 的账号和消息从独立的 Hub 数据库开始。

如果部署仍失败，打开 Cloudflare → Workers & Pages → `wechatduo` → Builds 中的失败构建，
查看最后的错误：缺少 `Hub` 类 / namespace 通常与迁移链有关；R2 bucket 不存在则需先创建上述桶。
`wrangler deploy --dry-run` 只验证本地打包，不验证线上迁移状态、账号权限或 R2 桶是否存在。

### 开启语音 / 视频通话（Cloudflare Realtime）

1. 在 Cloudflare 仪表盘创建一个 **Realtime（Calls）** 应用，拿到 App ID 和 App Secret。
2. 设置密钥并重新部署：

   ```bash
   npx wrangler secret put REALTIME_APP_ID
   npx wrangler secret put REALTIME_APP_SECRET
   # 可选：更好的 NAT 穿透（Realtime 的 TURN key）
   npx wrangler secret put REALTIME_TURN_KEY_ID
   npx wrangler secret put REALTIME_TURN_KEY_TOKEN
   ```

   也可以在仪表盘设置：Workers & Pages → `wechatduo` → 设置 → 变量和机密 → 添加，类型选“密钥”（Secret）。
   密钥与仪表盘添加的变量在每次从 main 部署后都会保留（`wrangler.jsonc` 设了 `keep_vars`）。
   仓库是公开的，不要把这些值写进 `wrangler.jsonc` 或提交到仓库。

未配置时，通话入口会提示“通话服务未配置”，其余功能照常。

### 新消息通知（无需配置）

推送服务自动配置：没有设置 VAPID 密钥时，服务器在第一次用到推送时自己生成一对，保存在 Durable Object 里，
之后一直用同一对；推送请求以应用自己的地址（例如 `https://wechat.cuven.us`）标明发送方。
iOS 需先用 Safari“添加到主屏幕”，再从主屏幕打开，在“设置 › 通知”里开启。

想用自己的密钥时再设置（可选）。换了密钥后，已开启通知的设备会在下次打开应用时自动重新订阅，不需要再次授权：

```bash
npm run vapid                          # 生成一对 VAPID 密钥
npx wrangler secret put VAPID_PUBLIC_KEY
npx wrangler secret put VAPID_PRIVATE_KEY
npx wrangler secret put VAPID_SUBJECT   # 可选，例如 mailto:you@example.com
```

### 表情（Telegram 表情包）

表情来自 Telegram 的公开表情包，由服务器用一个 Telegram 机器人的令牌去取（浏览器只和自己的服务器打交道，令牌不出服务器）。
在 Telegram 里找 [@BotFather](https://t.me/BotFather) 新建一个机器人（或用已有的），把令牌设为密钥：

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
```

**在应用里添加表情包**：表情面板顶部是自己的表情包，最后一个“+”列出可添加的表情包（封面、名称、数量），
点“添加”服务器就去 Telegram 取来，新包排在最前；点“移除”去掉。每个人的选择各自保存在服务器上，换设备也在。
可添加的包来自 `src/stickers.js` 里的预设名称表 `PRESETS`（手绘、游戏、巴黎奥运、小黄鸭、樱桃、动态 Emoji、几套猫和鸭子等）
加上 `STICKER_SETS`；服务器只读表里的包，不会替人去取任意的包。表里某个名字 Telegram 不认时，它不会出现在列表里。
想增减预设，改 `PRESETS`（`name` 是 `t.me/addstickers/<包名>` 里的那一段，`title` 是显示的名字）。

新账号一开始有 `HandDrawnEmoji` 与 `GameEmoji` 两个包。想换成别的，在仪表盘加一个普通变量 `STICKER_SETS`，
填包名，多个用逗号隔开，最多 8 个；这些包也会出现在可添加的列表里。每个包取前 120 个，每人最多 16 个包。

- 每个包在 R2 里保存 6 小时（`stickers/sets/`），Telegram 说不存在的包记住 1 小时；每个表情文件第一次有人看时从 Telegram 取一次，
  之后一直从 R2（`stickers/`）读。Telegram 暂时连不上时继续用上一次取到的包；移除了表情包后，旧消息里已经存下的表情照样显示。
- 表情消息带上所属的包名，所以对方没添加这个包也能看到。
- 动画表情（`.tgs`）在服务器上解压成 Lottie JSON，由随应用一起提供的 lottie-web（`public/js/vendor/`）播放；
  播放器第一次遇到动画表情时才加载。视频表情（`.webm`）静音循环。两者都只在屏幕上时播放，减少动态效果时停在静态图上。
- 没有设置 `TELEGRAM_BOT_TOKEN` 时，“+”面板里不显示“表情”，其余功能照常。

### 主屏幕应用占满屏幕

主屏幕应用使用默认状态栏样式（不用 `black-translucent`）。iOS 26.1 起（WebKit 301994，26.5 与 27 上再次出现），
用了 `black-translucent` 的主屏幕应用会得到一条不透明的状态栏，页面还会被截短一条状态栏的宽度，留下一条页面画不到的空白。
默认样式下页面占满状态栏以外的整个屏幕。iOS 在添加到主屏幕时读取这项设置，所以更新后需要删掉主屏幕上的
Cuven，再用 Safari 重新添加一次（登录状态会在添加时从 Safari 复制）。弹出表单时，状态栏的颜色随页面一起变暗。

### 配置项

| 名称 | 类型 | 说明 |
| --- | --- | --- |
| `SIGNUP_CODE` | secret，可选 | 注册邀请码；不设置则任何人都能注册 |
| `REALTIME_APP_ID` / `REALTIME_APP_SECRET` | secret | 语音 / 视频通话（Cloudflare Realtime SFU） |
| `REALTIME_TURN_KEY_ID` / `REALTIME_TURN_KEY_TOKEN` | secret，可选 | Realtime TURN，改善 NAT 穿透 |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` | secret，可选 | Web Push 通知的密钥与发送方；不设置时自动生成并保存，发送方为应用地址 |
| `TELEGRAM_BOT_TOKEN` | secret，可选 | 表情：用来读取 Telegram 表情包的机器人令牌；不设置则不显示表情 |
| `STICKER_SETS` | var，可选 | 新账号一开始就有的表情包，逗号隔开；默认 `HandDrawnEmoji,GameEmoji`；也可在应用里添加 |
| `DO_LOCATION_HINT` | var，默认 `apac` | Durable Object 首次创建的大致位置 |

## 本地开发

```bash
npm run dev          # wrangler dev，打开 http://127.0.0.1:8787 ，点“创建账号”
npm test             # 数据层与账号加密单测 + Web Push（RFC 8291 测试向量、声明式消息）+ 通话信令与 /rtc 代理 + 输入校验 + 表情管线（模拟的 Bot API）
```

- 本地 `wrangler dev` 自带内存版 Durable Object SQLite 和 R2，无需额外配置即可跑通聊天与媒体。
- 没有配置通话服务时，通话按钮不会出现。想本地试通话 UI 用 `npm run dev:e2e`
  （即 `wrangler dev --var REALTIME_APP_ID:dummy --var REALTIME_APP_SECRET:dummy`）：信令与来电界面可用，
  真正接通需要真实的 Realtime 应用。端到端测试（`tools/e2e/`）都跑在它上面。
- 界面走查脚本：`node tools/e2e/walkthrough.cjs docs/screenshots` 用 Playwright（Chromium）
  注册两个账号，跑一遍登录 → 找人 → 实时收发 → 手绘 → 通话界面 → 展开 / 深色，并截图。
- 交互回归：`node tools/e2e/design-details.cjs` 验证图片预览、拖放 / 粘贴、真实上传、失败重试、
  任意长度邀请码和 320px 窄屏；只连接本地服务，截图写入 `screenshots-design/`。
- 通话协商：`node tools/e2e/call-negotiation.cjs` 用页面内的第二个 RTCPeerConnection 充当 SFU，验证先发布、每个会话一次只改一处、
  接听方拉取早于自己就绪时公布的轨道、拉取失败重试。
- 双屏回归：`node tools/e2e/duo-layout.cjs` 验证照片叠放与展开、双账号回应与已读、相册切换与焦点恢复、
  分栏比例与两栏底部栏的项目和基线、模拟书本 / 笔记本折叠时的分栏与弹层位置、
  折叠前后的草稿 / 选区 / 阅读位置、小窗口发送；只连接本地服务。
- 安全区回归：`node tools/e2e/safe-layout.cjs` 按窗口尺寸、安全区与键盘检查 44pt 点按区域、
  通话与信息在标题右侧、“返回”在底部栏最前且与输入框同一行、“+ / 发送”在输入框后、按优先级溢出与焦点、200% 字号；
  使用前端示例数据，不创建服务端账号。
- 栏带回归：`node tools/e2e/strip.cjs` 依次走一遍 合上看对话 → 打开（列表 + 对话）→ 滑到对话 + 详情 → 合上看详情 →
  轻扫回到对话，并检查浏览器前进 / 后退、边栏范围、视野外的未读、折叠时保留正在使用的那一栏、减少动态效果；
  再按 [iphone-duo-web](https://github.com/trustworkscompany-dev/iphone-duo-web-skill) 的设备矩阵
  （466×678、678×466、951×669、890×626、669×951、626×890、475×669、669×475）检查栏数、居中的折痕间隙、溢出、
  44pt 控制只在标题行或底部栏，并把宽度在 466 ↔ 951 之间逐步拖动，确认折叠不会被误判为键盘、弹层不压在折痕上；
  另检查右侧 84pt 系统列与 376pt 页面下的底部栏。
- 折叠模拟：在地址后加 `?fold=vertical`（书本）或 `?fold=horizontal`（笔记本），或在控制台调用
  `(await import('/js/ui/viewport.js')).emulateFold({ axis: 'vertical' })`。

## 安全

- 密码用 PBKDF2-HMAC-SHA256（100k 轮）加随机盐哈希；会话是 HMAC 签名令牌（HttpOnly、SameSite=Strict）。
- 改密码会提升 epoch，使旧令牌失效（相当于全端退出）。
- 改状态的请求与 WebSocket 升级都做同源校验。
- 媒体下载响应带 `sandbox` CSP 与 `nosniff`，并按会话成员鉴权；上传限制大小与成员。
- 通话的 Realtime App Secret 只在服务端，浏览器只通过 `/rtc/*` 代理访问。
- Telegram 机器人令牌只在服务端；浏览器拿到的表情列表不含 Telegram 的文件 id。服务器只读预设名称表与 `STICKER_SETS` 里的包。
  表情消息只记录表情的 id、种类、emoji 和包名，服务器会校验；表情文件响应同样带 `sandbox` CSP 与 `nosniff`。
  lottie-web 从本站加载并校验 SRI。

## 已知限制

- 语音 / 视频通话需要配置 Cloudflare Realtime 应用；未配置时入口会提示。
- 暂不支持录制语音消息（可发文字、图片、手绘、表情；可打语音 / 视频通话）。
- 视频表情是 WebM（VP9）；浏览器放不了时显示它的静态图或 emoji。开发环境连不上 Telegram，取表情的流程只用模拟的 Bot API 测过；
  预设名称表里除了 `HandDrawnEmoji`、`GameEmoji`、`ParisOlympicEmoji`（游戏里用过）以外的包名来自公开的表情包目录，没有逐个在 Telegram 上核对，
  取不到的会自动从列表里消失。
- 单个 Durable Object 承载全部状态，适合个人与中小群体自建；超大规模需要分片。
- 非端到端加密：消息在服务端（你自己的 Cloudflare 账号）以明文存储。
- iPhone Duo 上的 Safari 没有折叠 API（不支持 CSS Viewport Segments 与 Device Posture）：折叠 / 展开只表现为宽度变化。
  栏带、等宽两栏与弹层分侧都只依赖宽度，在 Safari 上完整可用；书本 / 笔记本半折时让开折痕的细化只在提供视口分段的浏览器
  （Chromium）上生效，属于渐进增强。内屏的点网格是 951×669 还是 890×626 尚未确定，两者都已测试。
- 无法在真机上验证的部分：iOS 键盘动画、`<input switch>` 触感、Apple 推送送达、
  真实 Realtime SFU 接通质量（开发环境无法访问 Realtime 服务）、真机摄像头与安全区的实际数值。
- 折叠 / 展开过渡依赖浏览器的视图过渡（View Transitions，Safari 18 / Chromium 111 起）；不支持时直接切换。

## 目录

```
src/            index.js（瘦代理）· hub.js（Durable Object）· store.js（SQLite）
                auth.js（账号加密）· media.js（R2）· stickers.js（Telegram 表情 → R2）· call.js（Realtime 信令/代理）· push/
public/         index.html · manifest · sw.js · css/ · icons/
  js/           main.js · api.js · store.js
    ui/         视口与折叠、栏带（strip）、工具栏、符号与符号动效、弹簧、按压、外观、格式、触感
    views/      auth · sidebar · chatList · thread · artifact（详情栏）· bubbles · composer
                overlay · sheets · shell · viewer · call（通话）· draw（画板）· stickers（表情）· avatar
    vendor/     lottie-web 5.13.0 light（MIT，原样）
tools/          gen-vapid.mjs · gen-springs.mjs · gen-symbols.py · e2e/（walkthrough · design-details · duo-layout · safe-layout · strip）
test/           store · auth · webpush · call · stickers（表情管线）· *-runtime（Miniflare 上跑整个 Worker）
```

## 致谢

- 交互与视觉参考 iOS“信息”，并借鉴 **Benji Taylor** 的 Family（弹性物理与触感）、
  Honk（实时打字、无发送键）与 drawesome（手绘）。
- 语音 / 视频通话基于 [Cloudflare Realtime](https://developers.cloudflare.com/realtime/)（SFU）。
- Web Push 按 RFC 8291 / 8292 用 WebCrypto 实现。
- 动画表情用 [lottie-web](https://github.com/airbnb/lottie-web)（MIT，见 `public/js/vendor/lottie-web.LICENSE.md`）播放；
  表情包来自 Telegram。
