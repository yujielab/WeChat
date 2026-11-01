# Cuven 体验改进清单（用户体验设计师）

依据：README 功能与已知限制、design-qa.md、docs/screenshots、public/js 代码检查。
按“用户每天都会碰到的程度 × 缺失的痛感”排序。P0 先做。

## P0：聊天里最常用、目前缺失的功能

1. **引用回复**
   - 入口：长按菜单加“回复”；对方消息上向右轻扫也能触发（与左滑删除方向相反，不冲突）。
   - 输入框上方出现引用条：发送者名 + 原文一行截断 + ✕，复用现有“编辑消息”条（composer-edit-quote）的样式。
   - 发出后气泡顶部带浅色引用块；点引用块滚动到原消息并闪烁高亮 1 次；原消息已撤回时显示“原消息已撤回”。
   - 验收：私聊、群聊、图片 / 手绘 / 表情都能被引用；Esc 取消；草稿保留引用状态。

2. **群聊 @提及**
   - 输入 `@` 弹出群成员列表（按最近发言排序，可继续打字过滤），选中后插入高亮 token，退格整体删除。
   - 被 @ 的人：会话列表行显示红色“[有人@我]”，推送标题加“提到了你”，免打扰的群也提醒。
   - 进入会话后右下角出现“@ 1”胶囊，点击跳到那条消息。

3. **网络状态与发送可靠性**
   - 已有离线提示：会话列表的 `conn-status`（public/js/views/chatList.js:38）和 `.offline-banner`（public/css/list.css:135）。在这两处上改，不另做一套。
   - 补齐：对话页里也要能看到连接状态（目前只在会话列表），恢复后自动消失，不弹 toast；橙色文字按 hig-audit P0-1 换成 `#c93400`。
   - 离线时仍允许发送，消息停在“发送中”，恢复后按顺序补发；失败的消息保留现有“未发送 · 重试”。

4. **对话内跳转**
   - 未读较多时进入会话，定位到第一条未读，并显示“↑ N 条新消息”胶囊。
   - 用户往上翻时，新消息不强行滚到底，改为底部“↓ 新消息”计数胶囊。

## P1：完整度

5. **会话内搜索**：详情页加“搜索聊天记录”，结果高亮关键词，点击跳到原位置（复用第 1 条的跳转 + 高亮）。
6. **转发**：长按菜单加“转发”，多选目标会话，可附一句话。
7. **对方状态**：标题下的“在线”在离线时改为“最近在线 x 分钟前”；正在输入优先显示。
8. **设置页“通知”分组**：截图里这一组是空的（不支持或未加到主屏幕时）。改为始终显示一行带说明的禁用项，并给出“如何添加到主屏幕”的一步引导。
9. **语音消息**（README 已知限制）：按住录音、上滑取消、松手发送；气泡显示波形和时长。工作量大，排在 P1 末尾。

## P2：细节与质感（交给 UI 设计师一起看）

10. 自己发出的气泡旁不显示自己的头像（截图 04），节省横向空间，和 iMessage / 微信一致。
11. 时间分隔：间隔超过 5 分钟才插入时间，昨天 / 星期几 / 日期分级显示。
12. 空状态：新会话、没有联系人、搜索无结果，各给一句说明 + 一个主要操作。
13. 登录页：用户名 / 密码错误时在对应输入框下方就地提示，按钮加载中禁用，避免重复提交；“创建账号”时实时校验用户名是否可用。
14. 触感与动效：发送、回应、删除给轻触感；遵守“减少动态效果”。

## 第 5、6 步交互规格：发送键形变、双击点赞、长按菜单（UX交互体验设计师）

本节写 `docs/style-spec.md` 第五节第 5 步（输入栏）和第 6 步（回应与长按菜单）的交互，给代码工程师和 UI风格高精度复刻设计师照着做。分工是：**颜色、尺寸、圆角、阴影听复刻设计师的，状态、时序、手势、读屏、焦点听本节的**。本节和 `style-spec.md` 冲突时以 `style-spec.md` 为准，和 `docs/hig-audit.md`、`docs/quality-bar.md` 的底线（44pt、对比度、减弱动态效果）冲突时以底线为准。上面 P2 第 14 条「触感与动效」在发送键和回应上怎么落地，就是本节。

行号以 master `acb565c` 为准。

### 0. 通用约定（三项都适用）

- **只动 transform 和 opacity**：形变、上浮、心形都只改 `transform`/`opacity`，颜色变化用 `background-color`/`color` 过渡。不改 `width`、`height`、`top`、`left`、`margin`，不触发重排。唯一的例外是长按菜单首次定位时写一次 `left`/`top`，沿用 `overlay.js:426-427` 现状。
- **时长和曲线只用 token**（`tokens.css:153-176`，有 `linear()` 时是 `tokens.css:187-198` 的弹簧采样）：
  - 颜色和透明度：`--dur-quick` 160ms，`ease-out`。
  - 小位移：`--dur-ui` 240ms，`--ease-out`。
  - 弹簧：`--spring-snappy` / `--spring-snappy-dur`（266ms）、`--spring-bouncy` / `--spring-bouncy-dur`（403ms）。
  - 按下：`--press-in` 100ms，`--press-out` 190ms，`--press-scale`。
  - 不要新写 `cubic-bezier`，也不要写死毫秒数。现有写死的 `170ms`/`190ms`（`thread.css:495,497`）趁这次换成 `--dur-quick` 和 `--spring-snappy`。
- **减弱动态效果的写法**：两套开关都要写，`@media (prefers-reduced-motion: reduce) { :root:not([data-motion="full"]) … }` 和 `:root[data-motion="reduce"] …` 各一份，参照 `list.css:221-236`。JS 里判断用 `reducedMotion()`（`dom.js:112-117`）。
  - **注意**：`base.css:270-289` 在减弱模式下把所有 `transition-duration`/`animation-duration` 压成 0.01ms，而且带 `!important`。所以想要「100ms 以内淡入」，必须像 `list.css:228`/`list.css:236` 那样写成 `animation: fade-in 100ms linear backwards !important`，选择器还要比 `:root … *` 更具体。不写的话就是瞬时切换，这本身也合规。
- **降低透明度**：`.ctx-backdrop` 不是 `.glass`，`glass.css:185` 的 `prefers-reduced-transparency` 管不到它。要在同一个媒体查询里补上 `:root:not([data-glass="glass"]) .ctx-backdrop`，写法照抄 `overlays.css:412`（去掉模糊，背景用 `--scrim`）。
- **触感**：一律调 `haptic()`（`ui/haptics.js`）。iOS Safari **没有** `navigator.vibrate`，`haptic()` 是靠切换 iOS 18 的 `<input switch>` 来播放系统触感。它只在用户手势里才会响，而且用户可以在设置里关掉（`ui:haptics`）。不要直接调用 `navigator.vibrate`。安卓上 `haptic()` 不做任何事，这是有意的。
- **读屏播报**：一律用 `announce()`（`dom.js:137-142`，写进 `#announcer`）。播报要短，不要每敲一个字播一次。
- **点按区域**：所有可点的东西至少 44×44pt（`--hit`，`tokens.css:136`）。视觉上比 44 小时，用 `::after` 向外扩，参照 `glass.css:114`。

### 1. 发送键形变（第 5 步，输入栏）

**现状**：一个按钮 `.composer-action`（`composer.js:57-64`）里叠着三个图标，分别是 `action-add`（+）、`action-send`（↑）和 `action-save`（✓）。`setHasText()`（`composer.js:119-136`）切换 `.composer.has-text`，CSS 交叉淡入加缩放（`thread.css:497-508`）。
- 好处：始终是同一个元素，焦点不会丢。CSS 过渡可以中途掉头。`tools/e2e/motion.cjs` 已经验证过「Send takes the button's place without a second button」。
- 这个结构**保留**，第 5 步只换「空的时候显示什么」和配色。

#### 1.1 布局（按 `style-spec.md` 第二节「输入栏」那一行）

- **左边**：新增「+」按钮，打开现有的 `composer-panel`（照片、表情、手绘）。现有 `setOpen()`（`composer.js:140-161`）、`aria-haspopup`/`aria-expanded`、Esc 关闭的逻辑整体搬到这个按钮上。面板的生长原点从右下角改到左下角，涉及 `thread.css:539-567` 的 `clip-path` 和 `composer.js:146` 的 `getBoundingClientRect` 取哪个按钮。这个按钮要加进 `press.js` 的 `IMMEDIATE` 列表（`ui/press.js:6`）。
- **中间**：胶囊输入框，不变。
- **右边**：`.composer-action` 固定占位（宽度不变，所以输入框宽度不变，文字不会重新折行），按状态显示下表里的图标。
- **麦克风的前提**：现在还**没有**录语音（README「已知限制」：暂不支持录制语音消息，上面 P1 第 9 条）。所以分两期：
  - **A 期（现在做）**：空的时候右边是**相机**（`icon('camera')`，`index.html` 里已有这个符号），点了直接拍照（`<input type="file" accept="image/*" capture="environment">`），拍完走 `openImages(files)`（`composer.js:76`）。面板里的「照片」还是从相册选。这和 WhatsApp iOS 一样：相机在输入框右边，有字后被发送键替换。
  - **B 期（语音上线后）**：右边空的时候改成**麦克风**，相机挪进输入框内右侧，**有字时也不隐藏**。WhatsApp 有字时会藏起相机，但那样输入框宽度一变，文字就要重新折行，所以这里有意不跟。
  - 不允许出现点了没反应的麦克风。

#### 1.2 状态机

判断「有没有字」的规则：`value` 去掉空白后长度大于 0。空白包括 `\s`（含全角空格 `\u3000`），以及零宽字符 `\u200b-\u200d`、`\ufeff`。现在用的是 `trim()`（`composer.js:113`），零宽字符会被当成有字，要补上。预测补全的灰字（`predict.js`，画在 `.field-predict` 上，不在 `value` 里）不算有字。

| 状态 | 条件 | 右键图标 | 底色/图标色 | `type` | `aria-label` | 可用 |
|---|---|---|---|---|---|---|
| 空 | 没有字（含只有空格、换行、零宽字符） | A 期相机 / B 期麦克风 | 透明或 `--surface`，图标 `--label`（复刻设计师定） | `button` | A 期「相机」/ B 期「按住录音」 | 是 |
| 有字 | 有非空白字符 | ↑ `action-send` | `--brand-strong` 底，`--on-brand` 图标（浅色白字 5.4:1，深色黑字 8.9:1，`tokens.css:49-50,245-246`） | `submit` | 「发送」 | 是 |
| 组字中 | `compositionstart` 到 `compositionend` 之间 | **冻结在进入组字前的状态** | 不变 | 不变 | 不变 | 不变 |
| 编辑消息 | `editing` 不为空（`composer.js:252`） | ✓ `action-save` | 同「有字」 | `submit` | 「保存修改」 | 删空时不可用（`composer.js:120`，透明度 .4） |
| 引用回复中 | `.composer.replying` | 同「空」或「有字」 | — | — | — | 回复条不影响发送键 |
| 只读 | `readonly`（`composer.js:320-323`） | 「空」的图标 | 透明度 .4 | `button` | 不变，加 `disabled` | 否，双击和长按也不响应 |
| 离线 | `.offline-banner` 显示中 | **和在线完全一样** | 不变 | 不变 | 不变 | 是，文字进发件箱排队（`97f0551`），不把按钮置灰 |
| 有附件 | 附件面板 `openAttachments` 打开 | 不变（输入栏在面板后面，`inert`） | — | — | — | 面板里有自己的发送键；关掉面板后重新判断一次 |
| 录音中（B 期） | 按住麦克风 ≥ 250ms | 麦克风保持在原位，复刻设计师定是否变红 | — | `button` | 「正在录音，松开发送」 | 轻点（< 250ms）不录音，`toast('按住录音，松开发送')` |

**切换时机**：

- **打字和删除**：每次 `input`（不在组字中）都重新判断，不加防抖。CSS 过渡可以中途掉头，连续删加不会闪。
- **粘贴**（`inputType === 'insertFromPaste'`）：立刻切到「有字」。粘贴的内容全是空白时保持「空」。
- **删到空**（退格、剪切、全选删除）：立刻切回「空」。
- **发送后**：`submit()` 清空输入框后（`composer.js:186-188`）立刻回到「空」。焦点留在输入框（`composer.js:194`），键盘不收（`composer.js:292-293` 按下时的 `preventDefault` 保留）。
- **输入法组字**：
  - `compositionstart` 记下 `composing = true`，之后 `autosize()` 照常调整高度，但**不调** `setHasText`。
  - `compositionend` 把 `composing` 置回 `false`，然后立刻按当前 `value` 判断一次。Safari 的 `input` 可能在 `compositionend` 之前也可能在之后，所以两处都要判断。
  - 效果：输入框空着时打拼音「ni」，按钮保持相机，选中「你」上屏后才变成发送。拼音打到一半删光，按钮一下都不动。
  - 组字中按回车不发送，沿用 `composer.js:208` 的 `isComposing` / `keyCode === 229` 判断。
- **切换会话或恢复草稿**（`setChat`，`composer.js:310-330`）：直接显示目标状态，**不播形变**。做法是借现有的 `no-grow` 思路：`setChat` 时给 `.composer` 加一个「本帧不过渡」的标记，下一帧去掉（见文末「待报备的新 class」第 4 条）。
- **进入和退出编辑**：「空/有字 ↔ ✓」用同一套交叉淡入，不另做。

#### 1.3 动效

- **形变方式**：图标交叉淡入加缩放，**不做路径形变**。三个（B 期四个）图标叠在同一个 `grid-area: 1/1` 里（`thread.css:497`）。
  - 退场的图标：`opacity` 1 → 0，`--dur-quick`，`ease-out`；同时 `transform: scale(.8)`，`--dur-quick`，`--ease-exit`。
  - 进场的图标：`opacity` 0 → 1，`--dur-quick`；同时 `transform: scale(.6) → none`，`--spring-snappy-dur`，`--spring-snappy`。弹簧会略微冲过 1（约 1.005）再回来，这就是 WhatsApp 发送键「弹一下」的手感，不要另加关键帧。
  - 底色：`background-color` `--dur-quick` `ease-out`，从「空」的底色过渡到 `--brand-strong`。
  - 按钮本身不缩放、不移动，按下反馈沿用 `glass.css:112,116-123`（`--press-scale`）。
- **不用** `replaceSymbol()`（`symbols.js:154`）。它是先退场 120ms 再进场 300ms 的串行动画，一共 420ms，超过 350ms 的上限（`quality-bar.md` 第一节第 6 条），而且不能中途掉头。
- **左边「+」打开面板时**旋转 45° 变成 ×，沿用 `thread.css:537`，只是挪到新按钮上。

#### 1.4 减弱动态效果

- 图标和底色**瞬时切换**：图标 `transform: none !important`，沿用 `thread.css:710,718`；底色过渡由 `base.css:270-289` 压到 0.01ms。不需要额外淡入。
- 面板沿用 `thread.css:708-709,716-717`：不做 `clip-path` 生长，只切透明度。

#### 1.5 读屏与焦点

- `aria-label` 跟着状态变（见上表）。**状态变化不 `announce`**：打字时每切一次就播一次太吵。用户把焦点移到按钮上时，读屏自然会念出新名字。
- `type` 在 `button` 和 `submit` 之间切换（`composer.js:127`）。「有字」时去掉 `aria-haspopup` 和 `aria-expanded`，这一对现在挂在右键上（`composer.js:129-135`），A 期起改挂到左边的「+」上，右键不再带。
- 焦点：一直是同一个元素，形变前后焦点不丢。用键盘在按钮上按回车发送后，焦点留在按钮上，按钮已经变回「空」状态，不跳到别处。
- 发送不额外播报。离线排队的提示由发件箱负责，是代码工程师 `97f0551` 的现状。

#### 1.6 边界情况

- 只有空格或换行时按回车：不发送（`composer.js:175`），按钮保持「空」，不抖动。
- 输入框 5 行以上滚动时：按钮贴在底部不动（`align-items: flex-end`，`thread.css:413`）。
- 键盘弹出或收起：只有输入栏底部内边距变（`thread.css:417`），按钮不移动、不形变。
- 预测补全被接受（点灰字）：触发 `input`，按正常规则切换。
- 发送请求失败：输入框已经清空，按钮回到「空」。失败状态在消息上显示（「未发送 · 重试」），不回填到输入框。
- 断网时连按发送：每次都进队列，按钮每次都会回到「空」，不会卡在「有字」。

### 2. 双击点赞（第 6 步，回应）

**现状**：
- `thread.js:989-996` 只对 `kind === 'text'` 的气泡生效：同一条消息两次 `click` 间隔小于 340ms 就触发 `react(m, '❤️', { burst: true })`。已经点过赞的话，再双击会**取消**（`react()` 里 `thread.js:1048` 是切换逻辑）。
- 心形飘起：`.reaction-burst`（`thread.css:755-771`），760ms。回应胶囊弹出：`.m-reactions.pop`（`thread.css:750-753`）。
- 减弱动态效果时：飘心不生成（`thread.js:1052`），但 `.pop` 也只在 `!reducedMotion()` 时才加（`thread.js:321`），所以胶囊是瞬时出现的，没有 `style-spec.md` 要的「只淡入」。

#### 2.1 触发条件和判定

- **哪些消息能双击**：
  - `text`（包括大号纯 emoji 的 `.bubble.jumbo`）和 `sticker`。这两类单击本来就没有动作，所以双击不会让单击变慢。
  - `image`、`video`、手绘、`link`、`file`、`location`、`voice`、通话记录：**不支持双击**。它们单击就有主要动作（打开大图、链接、播放），等第二下会让单击慢 300ms 以上。这些消息用长按菜单里的表情行回应。
  - Instagram 的私信里图片也能双击，这里有意不跟。
- **只认触摸和触控笔**：`pointerType` 是 `touch` 或 `pen`。用鼠标双击是系统的选词（`hig-audit.md` P1-5 要在 `pointer: fine` 下开放文字选择），**不点赞**。鼠标用户右键打开菜单回应。实现上在 `pointerdown` 里记下 `pointerType`，`click` 时读出来。
- **判定窗口**：
  1. 两次点按都落在**同一个气泡**上，第二次 `pointerdown` 距离第一次 `pointerup` **不超过 300ms**。现在是两次 `click` 间隔 340ms，改用 pointer 事件计时，结果更稳定。
  2. 两次落点相距 **24px 以内**（按 CSS px 算）。
  3. 每次按住都**不到 250ms**。超过 460ms 已经算长按（`thread.js:1080`），按住期间移动超过 8px 算滚动（`thread.js:1099`），这两种都会把双击计数清零。
  4. 双击期间有过滚动（`scroll` 事件）也清零。
  5. 点在链接（`a`，`thread.js:985`）、「重试」（`.m-retry`）、回应胶囊（`.m-reactions`）、「已编辑」（`.m-edited`）上的不算点击气泡，不参与计数。
- **双击缩放**：`.thread-scroll` 是 `touch-action: pan-y`（`thread.css:13`），iOS 不会双击放大，这一条必须保留。
- **文字选择**：触屏上气泡是 `user-select: none`（`base.css:42-43`），双击不会选中文字。P1-5 只在 `pointer: fine` 下开放选择，和上面「只认触摸」正好错开。

#### 2.2 结果：只点赞，不取消（和现状不同）

- 双击的结果是**把我的回应设成 ❤️**，重复双击**不会取消**，和 Instagram 的双击一样。这样连点三四下不会忽有忽无。
  - 原来没有回应：加上 ❤️。
  - 原来是别的表情（比如 😂）：换成 ❤️，一人只能有一个回应，沿用 `withReaction`。
  - 原来就是 ❤️：**不发请求**，只重播一次飘心和触感，读屏念「已回应喜欢」。
- **取消回应**的方式不变：长按菜单里再点一次 ❤️（`react()` 的切换逻辑保留给菜单用），或者点回应胶囊打开菜单（`thread.js:984`）。
- 实现上给 `react()` 加一个参数，例如 `{ burst: true, keep: true }`；`keep` 为真时不做切换。
- **节流**：同一条消息 600ms 内只认一次双击，防止连点触发多次请求。

#### 2.3 哪些消息不响应

`reactable(m)`（`thread.js:45`）为假的消息，双击**什么都不做**：没有飘心、没有触感、没有播报。

| 消息 | 处理 |
|---|---|
| 已撤回或系统消息（`isSys`，`thread.js:42`） | 渲染成 `.sys`，没有 `.bubble`，自然不响应 |
| 发送中（`status: 'sending'` 或 `local:` 开头的 id） | 不响应，因为服务器上还没有这条消息 |
| 失败（`status: 'failed'`） | 不响应，「重试」才是这条消息的主要动作 |
| 只读会话 | 不响应 |
| 离线 | **照常乐观更新**：先显示 ❤️，请求失败就回滚，并 `toast('回应失败')`（沿用 `thread.js:1062-1065`）。回应不进发件箱 |

不给反馈，是为了避免让人以为已经回应了。

#### 2.4 视觉与触觉反馈

- **飘心**：沿用 `.reaction-burst`，但时长从 760ms 压到 **560ms 以内**：
  - 弹出段：`--spring-snappy-dur`，`--spring-snappy`。
  - 停留后淡出：`--dur-quick`。
  - 不接受点击（`pointer-events: none`，已有），不挡下一次操作。
  - 已经是 ❤️ 时重播飘心，胶囊不再弹。
- **胶囊**：
  - 新出现、或者数量变多时播 `.pop`（`--spring-bouncy`，403ms）。这是现有 token，比 350ms 略长，沿用不改。
  - 只是表情换了、数量没变时不播。
- **触感**：成功设上 ❤️ 时调一次 `haptic()`（`react()` 里已有，`thread.js:1050`）。点击事件里调用算在用户手势内，iOS 上能响。
- **离线回滚时**：不再调触感。

#### 2.5 减弱动态效果

- 飘心**不生成**（保持 `thread.js:1052`）。
- 胶囊**100ms 淡入**：`.pop` 改成无论是否减弱都加上（去掉 `thread.js:321` 的 `!reducedMotion()` 判断），再在两套开关下写：
  ```css
  :root[data-motion="reduce"] .m-reactions.pop { animation: fade-in 100ms linear backwards !important; }
  :root[data-motion="reduce"] .m-reactions.pop .m-reaction { animation: none !important; }
  ```
  媒体查询那一份同理，替换掉 `thread.css:772-777` 现在的 `animation: none`。
- 触感照常。触感不是动态效果。

#### 2.6 读屏

- 成功时 `announce('已回应喜欢')`（沿用 `thread.js:1057`）。已经是 ❤️ 时也念同一句，让读屏用户知道操作生效了。
- 读屏开启时，单指双击是系统的「激活」，会被当成一次 `click`。按 2.1 的规则（两次都要来自真实的触摸 `pointerdown`，且间隔不超过 300ms），读屏用户的一次激活不会误点赞。读屏用户通过长按菜单回应。
- 长按菜单里的回应必须一直保留：点 ❤️ 是点赞，再点一次是取消。双击「只点赞、不取消」只是触摸用户的捷径，不替代菜单。
- 每条消息再挂一个读屏能直接用的「点赞」动作：消息聚焦时，用 VoiceOver 转子的「操作」就能点赞，不用先打开长按菜单。实现上，在消息节点上加一个视觉隐藏、只有读屏能聚焦的「点赞」按钮，不加新 class，复用现有的视觉隐藏写法。（来自 Apple 设计标准管理师的 HIG 前提）

### 3. 长按菜单的上浮效果（第 6 步）

**现状**（结构保留，只按本节补齐）：
- `thread.js:1068-1112`：按住 460ms、移动超过 8px 或滚动就取消；右键、菜单键、Shift+F10 走 `contextmenu`。
- `thread.js:1117-1226` 的 `messageMenu()`：模糊背景 `.ctx-backdrop`，加上按原尺寸复制出来的气泡 `.ctx-preview`（`liftedCopy`）。上面是表情行 `.ctx-reactions`，下面是操作卡 `.menu.ctx-menu`，由 `place()`（`thread.js:1190-1208`）统一摆放。
- `overlay.js:306-563` 的 `openMenu()`：负责焦点、Esc、方向键、Tab 循环和点外面关闭。
- `tools/e2e/message-menu.cjs` 已经验证：浮起的副本和原气泡同尺寸、同行数、同字号、不缩放；所有东西都在安全区内、互不重叠。

#### 3.1 触发与状态机

```
idle ──pointerdown 在 .bubble 上──▶ pressing（.bubble.is-pressed，scale .97，thread.css:173）
pressing ──移动 >8px / scroll / pointerup / pointercancel──▶ idle（不打开，这次抬手后的 click 照常）
pressing ──按住满 460ms──▶ opening（haptic()；suppressClick = true，抬手后那次 click 被吞掉）
contextmenu（右键 / 菜单键 / Shift+F10）──▶ opening（不经过 pressing）
opening ──两帧后──▶ open（.ctx-backdrop.on、.ctx-reactions.on、.menu.on）
open ──Esc / 点背景 / 选了某项 / 消息消失 / 折叠形态变化──▶ closing ──220ms──▶ idle
```

- 460ms 保持不变：WhatsApp iOS 约 0.5 秒，比系统的 0.5 秒略短一点，手感更利落。
- `reactable(m)` 为假（发送中、失败、`local:`）时**照样打开菜单**，但没有表情行（现状 `thread.js:1167`）。失败的消息菜单里第一项是「重新发送」（`thread.js:1148`）。
- 已撤回的消息和系统提示没有 `.bubble`，不打开菜单。
- 照片组（`photoGroups`）没有表情行，沿用现状。

#### 3.2 上浮动效（「放大」和背景模糊）

- **气泡「放大」**：按住时气泡缩到 `scale(.97)`。打开的那一刻，副本从当时的缩放（`drawn` 和 `layoutSize` 的比值，约 .97）**弹回 1**，`transform` 用 `--spring-snappy-dur` 和 `--spring-snappy`。
  - 看起来是「被拎起来、变大了一点」，但停下来时**正好是原尺寸**，不放大超过 1。字号和折行都不变，`message-menu.cjs` 里 `scale === 1` 的断言照样成立。WhatsApp iOS 也不放大气泡。
  - 阴影沿用 `overlays.css:421`，阴影就是上浮的视觉信号。
- **需要挪位置时**：副本 `translateY` 用 `--dur-ui` 和 `--ease-out`（现在写死成 220ms，`overlays.css:418`，换成 token）。不加弹跳，这和现有注释的约定一致。
- **背景**：`.ctx-backdrop` 的 `opacity` 0 → 1，`--dur-quick`（现在写死 200ms，`overlays.css:410`）。`backdrop-filter: blur(26px) saturate(1.5)` 本身不做动画，只靠透明度淡入，避免逐帧重算模糊。
- **表情行**：
  - 从靠消息那一侧的下沿弹出（`--ox`，`thread.js:1205`），`transform` 用 `--spring-snappy`。
  - 六个表情逐个出现，间隔**从 22ms 改成 16ms**，单个用 `--spring-snappy-dur`。总时长 266 + 5 × 16 = 346ms，在 350ms 以内。现在是 360 + 5 × 22 = 470ms（`overlays.css:447`），超了。
- **操作卡**：沿用 `.menu` 的出场。
- **关闭**：表情行和操作卡淡出；副本回到原气泡**当前**的位置（见 3.5），背景淡出。全部结束后移除副本，原气泡恢复可见。

#### 3.3 靠近屏幕边缘时的翻转和避让

可用区域 `frame` 就是 `.menu-safe-frame`：四边各留安全区加 10px（`overlays.css:13`）；展开时只取当前栏（`fold.css:12-15`）。`place()` 的优先级如下，前三条是现状，后面是要补的：

1. **放得下就不动**：表情行（上）、消息、操作卡（下）三样都在 `frame` 里时，消息留在原位。
2. **下面不够**：整体往上挪，挪到正好放得下为止。靠近底部的短消息就是这种情况，也就是 `message-menu.cjs` 的第 1 个用例。
3. **上面不够**（消息贴着顶栏）：整体往下挪，表情行顶边不能超出 `frame.top`。
4. **消息太高**：消息只显示顶部，最少 44px，切口处渐隐（`.ctx-preview.cut`，`overlays.css:423`）。操作卡永远完整显示，超出 `frame` 高度时在卡内滚动（`overlay.js:419` 已经设了 `maxHeight`）。
5. **左右**：
   - 表情行和操作卡都和消息**同一侧对齐**：发出的消息右对齐，收到的左对齐（`thread.js:1201`），超出 `frame` 时往里收。
   - 表情行宽约 6 × 44 + 5 × 2 + 12 = 286px。`frame` 比这还窄时（窄栏），表情行改成在 `frame` 里横向滚动，仍然保持 44pt 一个，**不缩小按钮**。
6. **不做「操作卡翻到消息上方」**：WhatsApp 和 Instagram 都是表情在上、操作在下。为了放下而翻转，会让用户每次去不同的地方找「复制」。用第 2 条的挪位置代替翻转。

#### 3.4 iPhone Duo 的折叠和展开

- **折叠（单栏）**：`frame` 是整个屏幕减去安全区，规则同上。
- **展开（左列表、右聊天，`data-layout="split"`）**：`frame` 只取聊天这一栏（`placeOnSide(safeFrame, foldSide(trigger))`，`overlay.js:367`）。菜单和副本**永远不跨过铰链**，现状已经做到。
- **半开、横向铰链**（`data-fold="horizontal"`，用 `--fold-start`/`--fold-end` 表示，`viewport.js:147-152`）：**现在没处理，要补**。
  - `frame` 只取消息中心所在的那一半：上半是 `[frame.top, --fold-start]`，下半是 `[--fold-end, frame.bottom]`。
  - 消息正好压在铰链上时，取露出更多的那一半。
- **菜单打开时折叠或展开**（`data-posture` 变化，或 `onLayout` 回调）：**直接关掉菜单，不执行任何操作，不播动画**，焦点回到原消息。形态一变，副本位置就不可信了，硬去跟反而容易错位。

#### 3.5 键盘弹出和滚动时

- **键盘弹出时长按**：菜单拿走焦点后，iOS 会收起键盘（和 WhatsApp 一样）。键盘收起时 `visualViewport` 会变，`openMenu` 已经监听这个变化，重新定位（`overlay.js:459-461`）。
  - **要改的一处**：`place()` 现在用的是打开那一刻存下来的 `x`/`y`（`thread.js:1128-1129`）。要改成每次调用都重新量 `bub.getBoundingClientRect()`。这样键盘收起、消息列表跟着下移时，副本也跟着走（`transform` 过渡，`--dur-ui`）。
  - 菜单关闭后**不重新弹出键盘**。只有「编辑」「回复」这类本来就要聚焦输入框的操作，才由它们自己调用 `composer.focus()`。
- **滚动**：
  - 菜单打开时，对话不能滚动：背景盖住了整个对话，点背景就关闭（`overlay.js:541`）。
  - 按住阶段一旦滚动就取消长按（`thread.js:1103`）。
- **菜单打开时来了新消息**：消息列表是 `column-reverse`，底部钉住（`thread.css:10-14`），原气泡可能被往上顶。副本不跟着动，但**关闭时**要量原气泡的当前位置，副本收回到那里再移除。原气泡已经滚出可视区，或者已经不存在时，副本原地淡出。

#### 3.6 菜单打开期间消息发生变化

- **被撤回或被删除**（被对方撤回，或在另一台设备上删掉）：
  - 立刻关闭菜单，不执行任何操作。
  - 被撤回时 `announce('这条消息已撤回')`。
  - 焦点回到这个位置下一条消息的气泡；没有下一条就回到输入框。
- **被编辑，或回应有变化**：菜单保持打开。但菜单项的 `onSelect` 要在执行那一刻用 `msgOf` 按 id 重新取最新的消息，不能用打开时闭包里的 `m`（`thread.js:1148-1164` 现在捕获的是旧的 `m`）。按 id 取不到时 `toast('消息已不存在')`。
- **发送中的消息在菜单打开时发成功了**（id 从 `local:` 变成正式 id）：关闭菜单，焦点回到新节点。下次长按就会有表情行。

#### 3.7 减弱动态效果

满足「瞬时，或 100ms 以内淡入淡出」：

- `.ctx-preview`：`transform: none !important`。副本**直接出现在最终位置**，不弹、不挪。阴影照常。
- `.ctx-backdrop`：`animation: fade-in 100ms linear backwards !important`，模糊照常但不做动画。
- `.ctx-reactions`：`transform: none !important`，透明度 100ms。表情逐个出现的效果沿用 `overlays.css:661,663` 的 `animation: none`。
- `.menu.ctx-menu`：通用 `.menu` 在减弱模式下是 160ms 淡入（`overlays.css:546,557`）。**长按菜单这一族单独改成 100ms**，选择器写 `.menu.ctx-menu`，比 `.menu` 更具体，不影响其他菜单。
- 关闭：同样 100ms 淡出，或者瞬时消失。`overlay.js:498` 在减弱模式下已经不等过渡结束。
- 按下缩放：`--press-dur` 在减弱模式下是 0ms（`base.css:264-267`）。气泡的 `.is-pressed` 缩放由全局规则压成瞬时，可以接受。

#### 3.8 读屏和焦点

- **打开**：
  - 用键盘打开（`contextmenu` 来自菜单键或 Shift+F10）时，焦点落在第一项（`focusFirst: true`）。
  - 用触摸或鼠标打开时，焦点落在菜单容器上（`overlay.js:469`），读屏念「消息操作，菜单」。
  - `openMenu` 的 `title` 现在为空，`aria-label` 默认是「操作」（`overlay.js:313`）。长按菜单传 `title` 会显示标题行，所以**不传 `title`**，改为打开后把菜单的 `aria-label` 设成「消息操作」。
- **菜单内**：
  - Tab 在表情行和操作卡之间循环（`trapTab`，`overlay.js:522`）。
  - 表情行里用左右方向键（`thread.js:1178-1184`）；操作卡里用上下方向键、Home、End，也可以按首字母跳转（`overlay.js:515-539`）。
  - 表情按钮是 `menuitemradio`，`aria-checked` 表示我当前的回应（已有）。
- **关闭**：Esc（`overlay.js:511`）、点背景（`overlay.js:541`）、选中某一项。
- **焦点回到原消息**：这是**要补的**。现在 `restoreFocus(prevFocus)`（`overlay.js:504`）回到的是打开前的 `document.activeElement`，触摸打开时这个元素是 `body` 或输入框。改法：
  1. `messageMenu()` 打开前给原 `.bubble` 设 `tabindex="-1"`。这是现有做法，见 `thread.js:347`。
  2. 关闭时**先**恢复 `bub.style.visibility`，**再** `bub.focus({ preventScroll: true })`。现在恢复可见是在 `onClose` 里再等 220ms（`thread.js:1219-1223`），而 `visibility: hidden` 的元素拿不到焦点，所以顺序必须调过来。
  3. 例外：选中的操作会自己移动焦点时，以操作为准。「编辑」「回复」聚焦输入框，「查看图片」进入大图，「从本设备删除」或「撤回」后原气泡没了，焦点落在下一条消息，没有就落在输入框。
  4. 对程序设置的焦点，`:focus-visible` 只在键盘操作后才显示焦点环，触摸用户看不到多余的框。
- **播报**：
  - 选了表情：`announce('已回应…' / '已取消回应')`，沿用 `thread.js:1057`。
  - 复制：`toast('已复制')`，已有。
  - 打开菜单时不额外播报，菜单的名字就够了。
- **触感**：打开时调一次 `haptic()`（`thread.js:1087`）。**真机待验证**：这里是在 `setTimeout` 里调的，不在用户手势里，`haptics.js` 的注释说手势外可能不响。如果 iPhone 上不响，就改成 `pointerdown` 时预先准备好那个开关，计时器到点时再点它。改不好就接受长按没有触感。

### 4. 验收清单（复核时逐条勾选）

带 **[e2e]** 的条目可以写成 Playwright 脚本，接到 `tools/e2e/` 现有的套路上：浏览器本地造数据，拦截 auth 和 API，参照 `message-menu.cjs`、`motion.cjs`、`touch.cjs`。触摸用 CDP 的 `Input.dispatchTouchEvent`（`touch.cjs` 的做法），输入法组字用 CDP 的 `Input.imeSetComposition` 和 `Input.insertText`。减弱动态效果两种都要测：`page.emulateMedia({ reducedMotion: 'reduce' })`，以及 `document.documentElement.dataset.motion = 'reduce'`。折叠形态用 `emulateFold({ axis: 'horizontal', start, end })`（`viewport.js:158`）。带 **[真机]** 的只能在 iPhone 上看。

**发送键**
- [ ] [e2e] 空输入框：右键的 `aria-label` 是「拍照」（B 期是「按住录音」），`type="button"`，`.composer` 没有 `has-text`。
- [ ] [e2e] 只输入空格、换行、`\u3000` 或 `\u200b`：仍是「空」状态，按回车不发送。
- [ ] [e2e] 输入一个字：立刻有 `has-text`，`aria-label` 是「发送」，`type="submit"`。删到空：立刻回到「空」。
- [ ] [e2e] 粘贴一段文字：有 `has-text`。粘贴纯空白：没有。
- [ ] [e2e] `Input.imeSetComposition` 输入「ni」（未上屏）：没有 `has-text`，组字期间每一帧按钮的 class 和 `aria-label` 都不变。`Input.insertText('你')` 上屏后变成 `has-text`。组字中按回车不发送。
- [ ] [e2e] 发送后：输入框为空，按钮回到「空」，`document.activeElement` 仍是输入框。
- [ ] [e2e] 形变过程中，按钮的 `getBoundingClientRect()` 和输入框宽度保持不变（误差 ≤ 0.5px）。只有图标的 `opacity`/`transform` 和按钮底色在变。
- [ ] [e2e] 形变中途反向（打一个字，60ms 后删掉）：图标从当前值掉头，不跳到终点再回来。参照 `motion.cjs` 现有的 mid-flight 取样。
- [ ] [e2e] 切换到一个有草稿的会话：按钮直接是「有字」，第一帧取样就没有过渡中间值。
- [ ] [e2e] 编辑消息：✓，`aria-label` 是「保存修改」；删空后 `disabled`。退出编辑后恢复成原来的状态。
- [ ] [e2e] 只读会话：按钮是 `disabled`。
- [ ] [e2e] 离线（拦截 WebSocket，或模拟 `navigator.onLine = false`）：按钮外观和在线时一样，没有 `disabled`，发出去的消息进入「发送中」队列。
- [ ] [e2e] 减弱动态效果（两种开关）：切换后下一帧图标就是终态，`transform` 为 `none`。
- [ ] [e2e] 右键和左边「+」的点按区域都 ≥ 44×44（量按钮本身，或 `::after`）。
- [ ] [e2e] 浅色下发送键白色图标在 `--brand-strong` 上 ≥ 4.5:1，深色下黑色图标 ≥ 4.5:1（取像素算）。
- [ ] [真机] iOS 中文拼音、日文输入法：组字时按钮不闪。
- [ ] [真机] A 期点相机：直接打开相机，拍完进入附件面板。

**双击点赞**
- [ ] [e2e] 触摸双击一条文字消息（两次 tap 间隔 150ms）：出现 ❤️ 回应，`#announcer` 是「已回应喜欢」，`/api/react` 收到 `emoji: '❤️'`。
- [ ] [e2e] 两次 tap 间隔 400ms：没有回应。
- [ ] [e2e] 两次 tap 分别落在两条消息上：没有回应。
- [ ] [e2e] 两次 tap 相距超过 24px：没有回应。
- [ ] [e2e] 已经是 ❤️ 时再双击：仍然是 ❤️，没有发 `/api/react` 请求，播报「已回应喜欢」。
- [ ] [e2e] 已经是 😂 时双击：换成 ❤️。
- [ ] [e2e] 连点四下（每下间隔 120ms）：最多发一次请求，最终是 ❤️。
- [ ] [e2e] 鼠标双击文字消息：没有回应。
- [ ] [e2e] 双击图片：只打开一次大图，没有回应。单击图片后 100ms 内就开始打开大图，不等第二下。
- [ ] [e2e] 双击消息里的链接：只打开链接，没有回应。
- [ ] [e2e] 对发送中、失败、`local:` 开头的消息双击：没有回应，没有 `.reaction-burst`，`#announcer` 没有变化。
- [ ] [e2e] `/api/react` 返回 500：回应回滚，弹出「回应失败」的提示。
- [ ] [e2e] `.reaction-burst` 动画总时长 ≤ 560ms，元素在 `animationend` 后被移除。
- [ ] [e2e] 减弱动态效果（两种开关）：没有 `.reaction-burst`。`.m-reactions` 带 `.pop`，动画名是 `fade-in`，时长 ≤ 100ms，没有 `transform` 动画。
- [ ] [真机] iPhone 上双击有触感，设置里关掉触感后没有。

**长按菜单**
- [ ] [e2e] 按住 460ms 后菜单打开。按住期间移动 10px 不打开。按住 300ms 就抬手不打开，并且这次单击照常生效。
- [ ] [e2e] 打开时，副本在最终位置的 `scale` 为 1，尺寸、行数、字号和原气泡一致。这是 `message-menu.cjs` 已有的断言，必须继续通过。
- [ ] [e2e] 打开瞬间，副本的 `transform` 从小于 1 弹到 1（第一帧取样 `scale < 1`）。
- [ ] [e2e] 表情行动画总时长 ≤ 350ms（`animation-duration` 加上最后一个表情的 `animation-delay`）。
- [ ] [e2e] 底部的短消息、顶部的消息、很长的消息：表情行、副本、操作卡都在 `.menu-safe-frame` 以内，互不重叠，并且和消息同侧对齐。
- [ ] [e2e] 窄栏（`frame` 宽度 < 286px）：表情行可以横向滚动，每个按钮仍是 44×44。
- [ ] [e2e] 展开形态：所有元素都在聊天栏内，不跨过铰链。
- [ ] [e2e] `emulateFold({ axis: 'horizontal' })`：所有元素都在消息所在的那一半，不进入 `--fold-start` 到 `--fold-end` 之间。
- [ ] [e2e] 菜单打开时模拟折叠或展开：菜单关闭，没有执行任何操作，焦点回到原气泡。
- [ ] [e2e] 输入框有焦点时长按：菜单打开。之后改变 `visualViewport` 的高度（模拟键盘收起），副本跟着原气泡的新位置移动。关闭后焦点不回到输入框。
- [ ] [e2e] 用触摸打开：`document.activeElement` 是菜单容器，`aria-label` 是「消息操作」。按 Esc 关闭后，`document.activeElement` 是原 `.bubble`，并且这个气泡 `visibility` 不是 `hidden`。
- [ ] [e2e] 用键盘打开（先给气泡设 `tabindex="-1"` 并聚焦，再按 Shift+F10。消息目前不在 Tab 顺序里，这是现状，不在本节范围内）：焦点在第一项。Tab 在表情行和操作卡之间循环，方向键能走到每一项。
- [ ] [e2e] 点背景关闭：焦点回到原气泡，这次点击不会落到下面的消息上。
- [ ] [e2e] 选「编辑」：焦点在输入框。选「从本设备删除」并确认：焦点在下一条消息的气泡上。
- [ ] [e2e] 菜单打开时让这条消息被撤回（在本地 store 里改成 `revoked`）：菜单关闭，`#announcer` 是「这条消息已撤回」。
- [ ] [e2e] 菜单打开时来了一条新消息：关闭后副本收回到原气泡的**新**位置，不跳。
- [ ] [e2e] 发送中或失败的消息：菜单打开但没有表情行；失败的消息第一项是「重新发送」。
- [ ] [e2e] 减弱动态效果（两种开关）：`.ctx-preview` 的 `transform` 始终是 `none` 或只有定位用的 `translateY`，没有过渡。`.ctx-backdrop`、`.ctx-reactions`、`.menu.ctx-menu` 的淡入时长都 ≤ 100ms。
- [ ] [e2e] 系统开启降低透明度，或 `data-glass="solid"`：`.ctx-backdrop` 没有 `backdrop-filter`，背景是 `--scrim`。
- [ ] [真机] iPhone 上长按有触感（见 3.8 的风险）。长按不会弹出系统的放大镜或选择菜单。
- [ ] [真机] iPhone 横屏和 Duo 半开时位置正确。

### 5. 给实现者的提醒

**代码工程师**（`composer.js`、`thread.js`、`overlay.js`、`press.js`）：
1. 「+」挪到左边：`setOpen` 和面板定位（`composer.js:140-164`）改用新按钮。右键不再带 `aria-haspopup` 和 `aria-expanded`。新按钮要加进 `press.js:6` 的 `IMMEDIATE`。
2. 输入法组字：加 `compositionstart`/`compositionend` 的冻结逻辑；判断有没有字时把零宽字符也算作空白（1.2）。
3. A 期相机：加一个隐藏的 `input[type=file][capture]`，选到的照片走 `openImages()`。
4. 双击：改用 pointer 事件判定（300ms、24px、250ms、只认触摸和触控笔），扩展到 `sticker`，结果改成「只设不取消」，同一条消息 600ms 节流，`.pop` 在减弱模式下也要加（2.1、2.2、2.5）。
5. 长按菜单要补五处：
   - `place()` 每次都重新量原气泡的位置（3.5）。
   - 关闭时先恢复可见，再把焦点放回原气泡（3.8）。
   - 菜单项执行时按 id 重新取消息；消息被撤回或删除时自动关闭菜单（3.6）。
   - 横向铰链时 `frame` 只取一半；折叠形态一变就关闭菜单（3.4）。
   - 菜单的 `aria-label` 设成「消息操作」。
6. 这些都改到 `thread.js`。按最高决策权的排期，等你的发件箱合并以后再开工。

**UI风格高精度复刻设计师**（`thread.css`、`overlays.css`、`tokens.css`、`glass.css`）：
1. 发送键：「空」状态的底色和图标色由你定；「有字」和「编辑」用 `--brand-strong` 配 `--on-brand`。视觉尺寸小于 44 时用 `::after` 扩点按区域。
2. 把写死的时长换成 token：`thread.css:495,497`（170ms/190ms）、`overlays.css:410`（200ms）、`overlays.css:418`（220ms）、`overlays.css:444,447`（表情行，以及 22ms 改 16ms 的间隔）、`thread.css:763`（飘心 760ms 改成 ≤ 560ms）。
3. 减弱动态效果下补三处 100ms 淡入：`.m-reactions.pop`、`.ctx-backdrop`、`.menu.ctx-menu`/`.ctx-reactions`。两套开关都要写，并且要带 `!important`，才能盖过 `base.css:270-289`。
4. 降低透明度时 `.ctx-backdrop` 要退回纯色（第 0 节）。
5. 表情行在窄栏里横向滚动的样式（3.3 第 5 条），不加新 class，直接写在 `.ctx-reactions.menu-reactions` 上。
6. 涉及 `composer.js` 或 `thread.js` 的部分不要动，留给代码工程师。你这边只改 CSS 和 token。

**要最高决策权拍板的三件事**：
1. 双击从「再点取消」改成「只设不取消」（2.2）。
2. 语音没上线前，右键空着时先放相机（1.1 的 A 期）。
3. 飘心 560ms 和胶囊弹出 403ms 超过 350ms 上限，作为反馈动效的例外沿用现有弹簧 token。

### 6. 待报备的新 class

团队规定新 class 要先在群里报备。本节需要的如下，其余全部用现有的类名和 token：

1. **`composer-add`**：左边新的「+」按钮。`style-spec.md` 第 5 步把「+」从右键里拆出来成了独立按钮，现有的 `.composer-action` 已经是右键，不能复用。
2. **`action-camera`**：右键里的相机图标（A 期），和现有的 `action-add`/`action-send`/`action-save` 同一种命名。
3. **`action-mic`**：右键里的麦克风图标（B 期，语音上线时再加）。
4. **`.composer` 上的「本帧不过渡」标记**：用于切换会话和恢复草稿时不播形变。**优先复用现有的 `no-grow`**：把它也加到 `.composer` 上，CSS 写 `.composer.no-grow .composer-action, .composer.no-grow .composer-action .icon { transition: none; }`，这样不算新类名。复刻设计师如果认为 `no-grow` 挂在 `.composer` 上语义不清，再报一个 `no-morph`。

## 分工建议
- 代码工程师：1、2、3、4（前后端都要改 src/hub.js、src/store.js 与 public/js/views/thread.js、composer.js）
- UI 设计师：引用块、@token、网络横幅、跳转胶囊的视觉，以及第 10–12 条
- Bug 修复工程师：第 3 条的重连补发与顺序问题，回归现有 e2e
- Apple 设计标准管理师：按 HIG 审查新增的菜单、胶囊和横幅
- 我（用户体验设计师）：每项做完后按上面的验收点走一遍流程，结果追加到本文件末尾
