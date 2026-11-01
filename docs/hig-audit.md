# Cuven · Apple HIG 审查清单（Apple 设计标准管理师）

- 审查对象：`/workspace/shared/WeChat-main`，提交 **dff4523**（`ux: 体验改进清单 docs/ux-plan.md`），只读，未改任何源码。`public/` 与 `/workspace/team-chat-app/app/public` 内容一致，行号通用。
- 依据：Apple HIG 的 Accessibility（文字对比 ≥4.5:1，≥18pt 粗体 / 24pt 可 3:1；点按区域 ≥44×44pt；支持“增强对比度”）、Typography（Dynamic Type，最小 11pt）、Color（系统色要用可读的变体）、Layout（安全区）、Alerts / Action sheets / Undo（破坏性操作要确认或可撤销）、Dark Mode、Materials、Motion。对比度用 WCAG 2.x 公式实算。
- 已读 `design-qa.md`：纯黑 / 纯白主操作、蓝色只给“活的东西”、深色下发出气泡为白、浮动底部胶囊栏、少用说明文字、减少动态效果的处理都是有意的选择，本清单**不建议推翻**。
- 已读 `docs/ux-plan.md`：引用回复、@提及、网络状态、跳转、会话内搜索、转发、通知分组空白（#8）、自己气泡旁不显示头像（#10）、时间分隔（#11）、空状态（#12）、登录就地报错（#13）、触感（#14）不在此重复，做这些时请按下面的 token 和尺寸执行。
  - 补充一点：ux-plan #3 说“代码里没有离线提示”，其实已有 `chatList.js:38` 的 `conn-status` 和 `list.css:135` 的 `.offline-banner`。请在它们的基础上改，别另做一套。

## 总结

整体底子很好：系统字体栈 + `-apple-system-body` 跟随 Dynamic Type（`base.css:12-32`）、44pt 点按 token、`:focus-visible` 全局环（`base.css:64`，深浅色都 ≥5:1）、弹簧动效与减少动态效果、降低透明度都已具备。主要问题集中在四处：

1. 彩色文字和蓝色角标的对比度不达标。
2. 画板这一块的安全区、点按区域和读屏语义都有问题。
3. 有几处破坏性操作既不确认也不能撤销。
4. 一批写死 px / rem 的字号和圆角绕过了 token，导致 Dynamic Type 和整体质感不一致。

共 **19 项：P0 5 项，P1 6 项，P2 8 项**。

---

## P0（坏掉 / 无障碍硬伤）

### P0-1 彩色文字对比度不足（浅色模式）
- **问题**：橙色、蓝色用作小号文字时，对比度低于 4.5:1。
- **证据**：
  - `list.css:31` `.conn-status.warn { color: var(--orange) }`：#ff9500 在白底只有 **2.2:1**，字号 12px。
  - `thread.css:525` `.m-edited`：蓝色 11px 文字，#007aff 在白底 **4.02:1**。
  - `overlays.css:192` `.cell.tint`、`base.css:224` `.text-button`、`list.css:43` `.filter-note button`、`thread.css:518` 编辑条、`thread.css:626` “正在输入”：都是 `--blue` 文字，同为 4.02:1。
- **HIG 依据**：Accessibility › Color and effects：文字对比度至少 4.5:1；Color：系统色用于文字时要使用可读的变体。
- **建议改法**：在 `tokens.css` 新增文字专用 token，图标和填充继续用原色。
  - 浅色：`--blue-text: #0062cc`（5.8:1，可直接复用已有的 `--link-in`）；`--orange-text: #c93400`（5.3:1）。
  - 深色：`--blue-text: #0a84ff`（黑底 5.8:1）；`--orange-text: #ff9f0a`（10.2:1）。
  - 把上面各处的 `color: var(--blue / --orange)` 换成 `-text` 版本。
- **负责人**：UI 设计师（token）+ 代码工程师（替换）

### P0-2 未读角标“白字蓝底”对比不足
- **问题**：未读数是 11–12px 白字放在 #007aff 上，对比度 **4.02:1**，小字不达标。
- **证据**：`list.css:78` `.row-count`（.647rem ≈ 11px），`columns.css:57` `.side-count`（12px）。
- **HIG 依据**：Accessibility 对比度要求；角标属于必须读清的信息。
- **建议改法**：角标底色改为 `--badge-bg: #0062cc`（白字 5.8:1）；深色保持 `#0a84ff`，字改成黑色 `#000`（5.8:1）。不改“未读用蓝”的设计语言。
- **负责人**：UI 设计师

### P0-3 画板左右安全区写反
- **问题**：`margin` 简写的顺序是“上 右 下 左”，这里把 `safe-left` 写到了右边、`safe-right` 写到了左边。外屏右侧系统列有 84pt 安全区时，画布左边会多空 84pt，右边却伸进状态栏一列。
- **证据**：`draw.css:49` `margin: 0 calc(var(--margin) + var(--safe-left)) 0 calc(var(--margin) + var(--safe-right));`。同一文件第 22、63 行的顺序是对的。
- **HIG 依据**：Layout › 遵守安全区，内容不要落进系统区域。
- **建议改法**：改为 `margin: 0 calc(var(--margin) + var(--safe-right)) 0 calc(var(--margin) + var(--safe-left));`，并在 `safe-layout.cjs` 里加一条“画板 + 右侧 84pt 安全区”的断言。
- **负责人**：Bug修复工程师

### P0-4 画板颜色 / 粗细按钮：点按区域太小，读屏也读不懂
- **问题**：
  - 颜色按钮只有 30×30px，粗细按钮 36×36px，都没有扩展的点按区域。
  - 读屏名称是“颜色 #ff3b30”这样的十六进制色值。
  - 选中状态只用视觉表现（放大加一圈环），没有 `aria-pressed`。
- **证据**：`draw.css:90-92`（30px）、`draw.css:103-105`（36px）、`draw.js:19`（`aria-label: 颜色 ${c}`）、`draw.js:24`、`draw.js:126-133`（只切换 `.on` 类）。截图 `05-drawboard.png`。
- **HIG 依据**：Accessibility › 点按区域 ≥44×44pt；VoiceOver 标签要用自然语言，并说明状态；Color：不能只靠颜色或形状表达选中。
- **建议改法**：
  - 两类按钮都加 `::before { content:""; position:absolute; inset:-7px; }`（颜色按钮）/ `inset:-4px`（粗细按钮），按钮设 `position:relative`；调色板 `gap` 保持 ≥6px，避免点按区域重叠。
  - COLORS 改成 `{ c, name }` 结构，`aria-label` 用“黑色、红色、橙色、黄色、绿色、蓝色、紫色、粉色、白色”；粗细用“细、中、粗、特粗”。
  - `setColor` / `setSize` 同步设置 `aria-pressed="true/false"`，两组按钮外层加 `role="group"` 和 `aria-label`（“画笔颜色”“画笔粗细”）。
- **负责人**：代码工程师

### P0-5 会丢数据的操作没有确认
- **问题**：
  - 画板画了内容后点“关闭”，内容直接丢掉。
  - 长按消息里的“从本设备删除”立即执行，不能撤销。
- **证据**：`draw.js:135` `closeBtn → onClose()`，没有检查 `dirty`；`thread.js:1140` 和 `thread.js:945-947` 的 `deleteLocal` 直接调用 `removeMessage`。项目里已有 `overlay.js:566` 的 `confirmAction`，但只有“退出群聊”在用（`sheets.js:448`）。
- **HIG 依据**：Action sheets / Alerts：破坏性、不可恢复的操作要先确认，破坏性按钮用红色，并提供“取消”。
- **建议改法**：
  - 画板：`dirty` 为真时，点关闭弹出 `confirmAction(closeBtn, { title: '放弃这张手绘？', confirm: '放弃' })`；Esc 和下滑关闭走同一个判断。
  - 从本设备删除：用 `confirmAction`，标题写“只从这台设备删除，对方仍能看到”。
- **负责人**：代码工程师（UX交互体验设计师 定文案）

---

## P1（明显违反 HIG、影响体验）

### P1-1 删除聊天 / 退出登录没有撤销或确认
- **问题**：
  - 列表长按“删除聊天”、左滑删除、详情页“删除会话”都立刻执行。会话有新消息时会自己回来，但用户并不知道这一点。
  - “退出登录”一点就清掉缓存并刷新页面。
- **证据**：`chatList.js:375`、`sheets.js:412`、`sheets.js:165` → `main.js:296-300`。
- **HIG 依据**：Undo and redo：高频的破坏性操作，优先提供撤销而不是弹确认；Action sheets：退出登录这类改变全局状态的操作需要确认。
- **建议改法**：
  - 删除聊天：保留“直接删”的手感，删除后显示 toast“已删除聊天 · 撤销”，持续 5 秒；撤销时 `setFlag(id, { hidden: 0 })`，并把这一行放回原位置。
  - 退出登录：用 `confirmAction`（“退出登录？” / “退出登录” / “取消”）。
- **负责人**：代码工程师 + UX交互体验设计师

### P1-2 会话列表字号偏小，主次层级不够清楚
- **问题**：列表行里名字 15px、预览 13px、时间 11px，三者都比 iOS“信息”小一档。预览是用户扫列表时最主要读的内容，13px 读起来吃力。
- **证据**：`list.css:68`（.882rem）、`list.css:75`（.765rem）、`list.css:72`（.647rem）、`list.css:78`。截图 `10-unfolded-dark.png`。
- **HIG 依据**：Typography › iOS 默认字号：Headline 17、Subheadline 15、Footnote 13；次要信息不要低于 Footnote。
- **建议改法**：
  - 名字用 `var(--t-headline)` 加 600，预览用 `var(--t-subhead)`，时间用 `var(--t-footnote)`。
  - 行 `min-height` 保持 76px 就放得下，不影响 design-qa 里“展开后列表更紧凑”的约定。
  - narrow 和 leading 两个变体（`list.css:171-200`）同步修改。
- **负责人**：UI 设计师

### P1-3 一批字号写死成 px，不跟随 Dynamic Type，最小的只有 9px
- **证据**：
  - `duo-layout.css:53` `.bar-badge` 9px：低于 HIG 最小 11pt。
  - `thread.css:740` 回应胶囊 14px、`thread.css:749` 回应计数 11px。
  - `photo-stack.css:40/45/49` 11px。
  - `photo-stack.css:53` 查看器计数 13px。
  - `auth.css:24` 登录错误提示 12px。
  - `invite-code.css:5` 14px。
- **HIG 依据**：Typography › 支持 Dynamic Type；文字不小于 11pt。
- **建议改法**：
  - 全部换成 rem token：角标、计数用 `var(--t-caption-2)`（11），错误提示用 `var(--t-footnote)`（13），回应用 `var(--t-subhead)`。
  - 纯装饰的 emoji 大字（`thread.css:760/793`）可以保留 px。
  - 改完后在 200% 字号下重跑 `safe-layout`。
- **负责人**：UI 设计师 + 代码工程师

### P1-4 还有几个点按区域不到 44pt
- **证据**：
  - `insights.css:63` `.ins-fold` 是 36×36px（覆盖了 `glass.css` 的 44px）。
  - `overlays.css:646` `.menu-reaction` 宽 42px。
  - `auth.css:9` `.auth-tab` `min-height: 42px`。
  - `draw.css:103` 见 P0-4。
- **HIG 依据**：Buttons / Accessibility：所有可点控件 ≥44×44pt。
- **建议改法**：
  - `.ins-fold`：视觉保持 36px，加 `::before { inset:-4px }`。
  - `.menu-reaction`：`width:44px`，用 `justify-content:space-between` 吸收多出的宽度。
  - `.auth-tab`：`min-height:44px`，外层 `.auth-tabs` 的 padding 3px 不变。
  - 建议把这些控件也加进 `continuity` 的 44pt 审计（目前它只查“可见控件”，没有覆盖智能通知面板和登录页）。
- **负责人**：Bug修复工程师

### P1-5 消息正文不能选中部分文字
- **问题**：`body` 全局设置了 `user-select: none`，气泡里没有恢复。在桌面和 Duo 笔记本姿态下，用户无法拖选一段文字，只能通过长按“复制”整条复制。
- **证据**：`base.css:42-43`；`thread.css` 里没有任何 `user-select`；`thread.js:1126` 只有整条复制。
- **HIG 依据**：Text views / Pointer：文本内容在合适的情况下应当可以选择；iPadOS 和 macOS 用户习惯拖选文字。
- **建议改法**：
  - 加 `@media (pointer: fine) { .bubble { -webkit-user-select: text; user-select: text; } }`，触屏保持现状，避免和长按冲突。
  - 触屏上在长按菜单里加一项“选择文本”：进入可选模式，用系统的选区把手。
- **负责人**：代码工程师

### P1-6 “增强对比度”只照顾到玻璃材质
- **问题**：`prefers-contrast: more` 只改了玻璃描边。次要文字、分隔线、开关关闭态的轨道都没有增强。开关关闭态轨道 `--fill`（20% 灰）在白底只有约 1.2:1，看不出开关的边界。
- **证据**：`glass.css:205-213`；`tokens.css:23-31`；`overlays.css:246`（开关轨道）；截图 `37-settings.png` 中两个关闭态开关几乎看不见轮廓。
- **HIG 依据**：Accessibility › 支持“增强对比度”；控件边界的对比度 ≥3:1。
- **建议改法**：在 `tokens.css` 增加 `@media (prefers-contrast: more)` 块。
  - 浅色：`--label-2:#3a3a3c; --label-3:#6c6c70; --separator:rgb(60 60 67/.5); --line:#c7c7cc; --fill:rgb(120 120 128/.42);`
  - 深色：`--label-2:rgb(240 240 250/.8); --label-3:rgb(240 240 250/.6); --line:rgb(240 240 250/.3)`
  - 另外，`.switch` 关闭态在 `prefers-contrast: more` 下加 `box-shadow: inset 0 0 0 1px var(--separator)`。
- **负责人**：UI 设计师

---

## P2（打磨 / 质感）

### P2-1 输入框的焦点光晕几乎看不见
- **证据**：`--focus-ring` 只有 7% 黑（`tokens.css:18`），和白底对比 **1.17:1**；输入框聚焦时主要靠 1px `--label-3`（3.26:1）。见 `thread.css:432`、`list.css:116`、`overlays.css:587`。
- **建议改法**：
  - 键盘聚焦（`:focus-visible` 或 `.is-focused` 配合键盘来源）时改为 `0 0 0 2px var(--label-2)`。
  - 触屏聚焦可以保留现在的轻光晕，不影响 design-qa 里极简的方向。
- **负责人**：UI 设计师

### P2-2 圆角 token 形同虚设，同心圆角也没有对齐
- **证据**：
  - `tokens.css:118-122` 定义了 `--r-bubble/card/tile/menu/sheet`，但全项目只有 `draw.css:50` 用到 `--r-tile`。
  - 实际用到的 border-radius 有 **35 种**（2、3、5、6、7、8、9、10、11、12、13、14、15、16、18、20、22、23、24、25、26、28、30px……）。
  - 气泡是 23px（`thread.css:161`），token `--r-bubble` 却是 20；列表行 18 和 16 两种并存（`list.css:60/189`）；长按菜单卡片 26pt，弹层 30。
- **HIG 依据**：Layout / Materials：嵌套圆角要同心，即内层圆角 = 外层圆角 − 间距。
- **建议改法**：
  - 收敛到 6 级：`--r-xs 8`、`--r-s 12`、`--r-m 18`（行、卡片）、`--r-l 23`（气泡）、`--r-xl 26`（菜单）、`--r-sheet 30`，胶囊统一 999px。
  - 内层元素用 `calc(var(--r-外) - 内边距)`。例如菜单 26 − 6 = 20，那么菜单高亮条就用 20。
- **负责人**：UI 设计师

### P2-3 字号绕过 token
- **证据**：`list.css` 里有 31 处 `font-size`，大量写的是 `.882rem`、`.824rem`、`.765rem`、`.706rem`、`.647rem`、`1.882rem`、`1.765rem`（如 `list.css:27/29/40/47/53/125/130/162/186`）。其中 `.824rem`（14px）和 `1.882rem`（32px）不在 HIG 字号表里。
- **建议改法**：全部映射到 `--t-*`（large-title 用 `--t-large-title` 34px，窄屏用 `--t-title-1` 28px）。以后新增的样式禁止裸写 rem。
- **负责人**：UI 设计师

### P2-4 深色 token 复制了两份，同一块里还有冲突
- **证据**：
  - `tokens.css:200-260`（跟随系统）和 `262-320`（手动选择深色）逐行重复。
  - 每块里 `--bubble-card` 都被定义了两次：`#111113` 在第 230 / 291 行，`#1c1c1e` 在第 253 / 314 行，后者生效，前者是死代码。
  - 头像颜色在 `base.css:290-295` 也重复了一份。
- **风险**：以后改深色只改了一处，两种深色入口就会不一致（深色模式不对等）。
- **建议改法**：
  - 启动时由 JS 根据 `matchMedia` 设置 `data-theme`，CSS 只保留 `:root[data-theme="dark"]` 一块。
  - 或者用 `@custom-media`、构建脚本生成。
  - 删掉多余的那个 `--bubble-card`。
- **负责人**：代码工程师

### P2-5 “+”面板中间有一段空白
- **证据**：截图 `31-tools-open.png`：“照片”“手绘”两行下面到“×”之间空了约 60pt，面板显得松散，不像系统菜单那样紧凑。
- **HIG 依据**：Menus：菜单高度贴合内容，行高一致。
- **建议改法**：面板高度 = 行数 × 52pt + 按钮 56pt + 8pt 内边距；有“表情”时行数为 3。“+ → ×”的形变动效（design-qa M02）保留。
- **负责人**：UI 设计师 + UX交互体验设计师

### P2-6 设置里的 › 箭头没有垂直居中
- **证据**：截图 `37-settings.png` 中，“修改密码”右侧的 › 比文字基线低约 4pt。`overlays.css:190` `.cell .chev` 没有设置对齐方式。
- **建议改法**：`.cell .chev { display:grid; place-items:center; align-self:center; width:14px; height:14px; }`。“资料卡”的 `::after ›`（`overlays.css:225`）也统一改成 `chevron-right` 符号，不再用字符。
- **负责人**：UI 设计师

### P2-7 深色模式下，画板的黑色色块看不见
- **证据**：`draw.js:10` 里第一种颜色是 `#18181b`，它放在深色玻璃调色板上没有边框；`draw.css:101` 只给白色色块加了描边。
- **HIG 依据**：Dark Mode：每个元素在两种外观下都要能辨认。
- **建议改法**：深色下给 `.draw-color[style*="#18181b"]` 加 `box-shadow: inset 0 0 0 1px var(--separator)`；更好的做法是统一给所有色块加 `inset 0 0 0 1px var(--image-outline)`。
- **负责人**：UI 设计师

### P2-8 给 ux-plan 新增部件的 HIG 规格（提前约定，避免返工）
- **引用条**（ux-plan #1）：复用 `.composer-edit` 的结构，左侧 3pt 竖线用 `--blue`，名字用 `--blue-text`（见 P0-1）13pt semibold，原文 13pt `--label-2` 单行省略；✕ 的点按区域 44pt。
- **跳转胶囊**（ux-plan #4，“↓ 新消息”“@ 1”）：高 36pt（点按区域扩到 44），`--glass-tint-strong` 加 `--glass-shadow`，数字用 `tabular-nums`；出现时 `--spring-snappy`，减少动态效果时只淡入。
- **网络横幅**（ux-plan #3）：直接复用 `.offline-banner`，文字颜色用 `--orange-text`，`role="status"`，不弹 toast。
- **@ token**：底色 `--blue-ring`，文字用 `--blue-text`，圆角 6px；退格时整体删除，读屏读作“提及 某某”。
- **负责人**：UI 设计师；做完后交给我复审。
