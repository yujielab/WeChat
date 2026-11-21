# Cuven for iOS · 原生应用

用 **SwiftUI + UIKit** 从零写的原生 iOS 客户端，对接同一个 Cloudflare 后端（`src/`），
Web 端（`public/`）作为界面与交互的参照。不是网页套壳：没有 WKWebView，所有界面、动效、
相机、录音、手绘、通话都是系统原生实现。专门为 **iPhone Duo**（外屏折叠 / 内屏展开）适配，
普通 iPhone、Pro Max 横屏和 iPad 同样可用。

- 用 **Xcode 27.2 / iOS 27.2 SDK** 构建，最低系统 iOS 26；全部玻璃控件是系统 **Liquid Glass**
  （`glassEffect`，可交互、会折射），“降低透明度”或设置里的“Reduce transparency”时为实色。
- **与 Web 端一致**：颜色、字号、圆角、间距、动效时长直接取自 `public/css`（`tokens.css`、`thread.css`、
  `list.css`、`overlays.css`……），图标是 `public/index.html` 里的同一套 SVG 符号，由
  `ios/tools/gen-symbols.py` 转成原生路径（`Design/Symbols.generated.swift`），不是 SF Symbols 的近似。
- 依赖（Swift Package）：[lottie-spm](https://github.com/airbnb/lottie-spm)（动画表情）、
  [WebRTC](https://github.com/stasel/WebRTC)（语音 / 视频通话）。
- 字体：Clarinetta（由 `public/fonts` 转成 OTF 并补全字体名表），中文自动回落苹方；跟随“动态字体”。
- **全屏页面**：动态、回忆、朋友、我、设置、个人主页和各个编辑页都占满整屏，标题浮在页面上方的栏里，
  内容从它下面滚过（系统的柔和滚动边缘）；Duo 上返回、操作按钮在系统列的玻璃栏里，其他机型在浮动栏两侧。
  个人主页的封面一直铺到屏幕边缘，滚过封面后标题栏垫上模糊的封面。
- **界面语言**：英文与简体中文（`Resources/zh-Hans.lproj/Localizable.strings`），跟随系统语言。

## 拿到 IPA

每次推送 `ios/**` 都会触发 GitHub Actions（`.github/workflows/ios.yml`，`xcode-27` 运行器 + Xcode 27.2）：

1. 打开仓库 **Actions › iOS IPA**，点最新一次运行，在 **Artifacts** 下载 `Cuven-ipa`（解压得到 `Cuven.ipa`）。
2. 公开的下载链接在仓库的 **Releases** 里。发布新版本的三种方式：**Actions › iOS IPA › Run workflow** 并勾选
   *Attach the IPA to a GitHub Release*；推送 `ios-v1.0.0` 这样的标签；或者推送一个提交信息里带 `[ios-release]` 的提交。

### 安装

默认产物是**未签名**的 IPA（`CODE_SIGNING_ALLOWED=NO`），需要用自己的 Apple ID / 证书重签后安装：

- **Sideloadly / AltStore / SideStore**：选中 `Cuven.ipa`，用自己的 Apple ID 签名安装（免费账号 7 天有效）。
- **TrollStore**（支持的系统版本）：直接安装。
- **自己的开发者证书**：见下一节，让 CI 直接产出签名好的 IPA。

### 让 CI 直接签名（可选）

在仓库 **Settings › Secrets and variables › Actions** 添加：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12` | 证书 + 私钥导出的 `.p12`，再 `base64` |
| `IOS_CERTIFICATE_PASSWORD` | `.p12` 的密码 |
| `IOS_PROVISION_PROFILE` | `.mobileprovision` 的 `base64` |
| `IOS_EXPORT_METHOD` | 可选：`ad-hoc`（默认）/ `development` / `app-store` / `enterprise` |
| `IOS_BUNDLE_ID` | 可选：与描述文件一致的 Bundle ID（默认 `us.cuven.app`） |

设置后每次构建会多出一个 `Cuven-signed-ipa`。

### 本地用 Xcode 打开

```bash
brew install xcodegen
cd ios && xcodegen generate && open Cuven.xcodeproj
```

`project.yml` 是工程的唯一来源，`Cuven.xcodeproj` 不进仓库。

## 连接服务器

应用里不显示也不能修改服务器地址：服务器写在 `Core/AppModel.swift` 的 `defaultServer`，自己部署时改这里再构建
（截图用的 CI 通过环境变量 `CUVEN_SERVER` 指向本地 hub）。服务器出错时界面只显示“出了点问题，请重试”，
不显示状态码或内部信息。不需要改后端：

- 会话：服务器下发的 `cfm_session` Cookie 存进**钥匙串**（按服务器分别保存），每个请求手动带上；
- 同源校验：Worker 只接受带本站 `Origin` 的写请求和 WebSocket 升级，原生端每个请求都带上同样的 `Origin`；
- 时区：和 Web 端一样带 `x-tz`，作息与习惯按你的时区统计。

账号、消息、联系人、便签、动态、回忆、表情、通话、智能输入与 Web 端完全互通，消息格式（`meta` 字段、
`localId` 去重、回复快照、通话记录）与 `public/js` 保持一致。

## iPhone Duo 适配

按 Apple《针对 iPhone Duo 设计》与 Web 端的“栏带”方案实现（`Cuven/Layout/`）：

- **一条栏带，一个窗口**：边栏 | 列表 | 对话 | 详情 四栏排成一条。窗口宽度 < 700pt（外屏、普通 iPhone 竖屏）
  看一栏，≥ 700pt（内屏 951pt、Pro Max 横屏 956pt、iPad）看相邻两栏。前进时窗口向右滑一栏，返回向左；
  从左缘轻扫 1:1 跟手，松手按速度决定完成或弹回。
- **折叠 / 展开保持状态**：正在使用的那一栏留在屏幕上（展开时看着对话与详情，合上后是详情；在对话里输入，
  合上后仍是对话），草稿、滚动位置、焦点都不丢。
- **分栏宽度**：完全展开时导航窄（约三分之一，300–380pt）、对话宽，而且对话不论旁边是列表还是详情都保持同一宽度；
  设置 › 显示 › “展开时等宽”对应像书一样半折的姿态，两栏以折痕为界等宽，折痕两侧一层淡阴影。
- **侧栏（系统列）**：Duo 的状态栏和灵动岛在屏幕尾侧占一整列。原生端从安全区读出这一列（尾侧明显宽于首侧时），
  把当前最右一栏的控制竖排进这一列：返回 / 关闭在最上，其后是操作（对话：返回、语音、视频、聊天信息），
  从相机和状态栏下方开始（外屏 170pt、内屏 118pt），正对状态栏时钟的中线；输入框留在这一列之前。
  内屏展开时左栏仍用底部栏、右栏用侧栏。普通 iPhone 横屏两侧安全区一样宽，不会被当成 Duo。
- **页面胶囊**：Duo 的系统列底部一个竖向胶囊：Chats、Moments、Memories、Friends、You、Menu，
  当前页的浅色圆底在切换时滑过去；栏里“开始某件事”的按钮（边栏的 Search、手绘板的撤销 / 重做）站在胶囊正上方。
  页面以纸张样式的 sheet 打开（外屏贴内容区、内屏居中的表单），背后的栏带缩小后退。
- **铰链与折痕（iOS 27.1+）**：`onHingeChange` 读出合上 / 半折 / 放平，`reservedRegions(kind: .division)`
  读出折痕的位置；半折像书一样时两栏以折痕为界，折痕两侧一层淡阴影。
- **底部栏**：没有系统列的设备，每一栏的控制在底部 56pt 的栏里，单手可及：
  离开这一栏的按钮在左下角，单个操作是圆，成组的是胶囊，中间是搜索框或输入框；随键盘上移。
- **网格用偶数列**：回忆、聊天信息里的照片墙都是四列，个人主页图片墙两列瀑布流。
- 每一栏只拿它真正接触到的那条边的安全区（左栏不吃右侧系统列、右栏不吃左侧），所以内容不会被系统列挤压。

## 界面与动效（与 Web 端一致）

- **消息**：Facebook 蓝的自己气泡、浅灰的对方气泡，23pt 圆角（单行即胶囊），同组相接处收成 8pt，
  每组最后一条那个角变成小尖角；同一人 3pt、换人 12pt；静默 5 分钟或换日插入时间（系统字体 12pt，
  当天第一个写出 Today / Yesterday）；未读分隔“New messages below”；系统提示是浅黄小底板。
- **长按消息**：对话整体模糊，这条消息原样浮起，顶部是完整发送时间，回应胶囊在上、操作卡片在下
  （Reply / Copy / Select text / Edit…，再一段 Unsend / Delete for me），靠近底部时整体上移刚好够的距离。
- **双击爱心**、**右滑回复**（越过阈值有触感）、点回复引用跳回原消息并高亮。
- **实时输入预览**（Honk 式）：对方正在打的字实时出现在虚线气泡里；可在设置里关闭“Live typing”。
- **输入框**：56pt 的胶囊，“+”在框内右端，按下从按钮处长出 212pt 的附件卡片（照片、相机、手绘、表情、文件），
  “+”转成“×”；框外是麦克风圆钮，有字时原位变成墨色的发送（编辑时是 ✓）；回复 / 编辑时框顶出现一条引用，
  框变成圆角矩形；智能续写以建议胶囊给出；群聊里输入 @ 弹出成员列表。
- **玻璃**：全部是透明（Clear）的 Liquid Glass，不再提供着色选项；输入框后面没有弥散光。
- **照片**：从气泡放大到全屏、下拉缩回原处；双指 / 双击缩放；分享与保存。
- **手绘板**（PencilKit）：钢笔、马克笔、荧光笔、铅笔、橡皮站成一排（手里那支升高，笔尖是当前颜色），
  五色 + 色轮、粗细、空白 / 横线 / 方格纸，独立的撤销 / 重做。
- **通话**（WebRTC，经 `/rtc` 走 Cloudflare Realtime SFU，与 Web 端互通）：深色背景上的大头像或对方画面，
  顶部胶囊显示时长，底部深色玻璃胶囊（摄像头、翻转、静音 / 扬声器、红色挂断），自己的小窗可拖到角落；
  可缩成顶部药丸继续聊天。
- **聊天列表**：便签（24 小时的一句话，浮在头像上的思考气泡）、筛选胶囊（选中滑过去）、左右滑：
  置顶 / 未读 / 免打扰 / 删除，长按预览最近几条消息。
- **动态**：Instagram 式信息流、头像环（有新动态带彩色环）、多图左右滑、双击点赞爱心、评论、定时发布、
  谁能看 / 谁能评论、圈人、ALT 描述；个人主页封面、Posts / Media。
- **回忆**：按月分组的四列网格、本月回顾卡片自动轮播、按聊天或人名搜索。
- 所有按压都是即时轻压（0.97）+ 弹簧回弹，触感反馈可关；遵循“减少动态效果”“降低透明度”和动态字体。

## 已知限制

- **推送**：后端只支持 Web Push（VAPID），原生 App 收不到 Web Push。App 在前台或刚切到后台时会用本地通知提醒新消息；
  App 完全退出后的推送需要后端增加 APNs（需要 Apple 开发者账号的 .p8 密钥），目前未做。
- **视频表情**（`.webm`）：iOS 无法播放 WebM，显示其静态图；静态与动画（Lottie）表情正常。
- 未签名的 IPA 需要自行重签；免费 Apple ID 签名 7 天后需要重签。
- GitHub 托管的 macOS 运行器上 iPhone Duo 模拟器无法启动（Data Migration Failed），所以 CI 截图
  （`.github/workflows/ios-screens.yml`）用 `CUVEN_EMULATE=outer|inner` 在 iPad 模拟器里按外屏 466×678 / 内屏 951×669
  和系统列宽度排版后裁出；真机与本地 Duo 模拟器走系统的安全区、铰链和折痕 API。

## 目录

```
ios/
  project.yml                 XcodeGen 工程定义（依赖、Info.plist、签名设置）
  Cuven/
    App/                      入口、根视图、通知点击
    Core/                     APIClient（Cookie / Origin）、WebSocket、模型、AppModel（状态 + 发送队列）、图片缓存
    Design/                   颜色与字体、玻璃、按压、头像、通话背景光、格式化
    Layout/                   iPhone Duo 栏带（Nav、MainView、ColumnBar、安全区与键盘）
    Features/
      Auth/ ChatList/ Sidebar/ Thread/ Details/ Draw/ Stickers/
      Contacts/ Moments/ Memories/ Settings/ Viewer/ Calls/
    Resources/                图标、强调色、Clarinetta 字体
```
