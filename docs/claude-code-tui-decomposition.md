# Claude Code TUI 拆解

本文优先以可运行的 `claude-code/` 为准，必要时参考 `claudecode/`。目标不是照抄 Claude Code 的 UI，而是先把它的职责边界看清楚，尤其是这次用户明确指出的三件事：

- header 不是固定宽度字符串
- 等待 LLM 时输入框仍然保留，而且还能继续输入
- interrupt、queued input、后台任务和 UI 渲染不是一条同步链，而是多层异步状态协作

## 1. 先说结论

Claude Code 的 fullscreen TUI 不是“读一行输入 -> 阻塞等模型 -> 再读下一行输入”。

它更接近两个正交系统同时工作：

1. 布局系统
   负责 scrollable transcript、sticky header、new messages pill、固定底部输入区、modal overlay。
2. 任务系统
   负责 prompt input、queued command、query guard、interrupt、tool permission、agent task、后台通知。

关键点：

- 主滚动区和输入区是分离的。
- fullscreen 顶部固定的不是欢迎 header，而是滚动派生出来的 sticky prompt header。
- 欢迎 header 本身是内容的一部分，不是全局固定 chrome。
- 等待 LLM 时输入组件仍然挂在树上，只是 `isLoading=true`。
- 当前 turn、queued input、interrupt、agent 状态更新可以并行存在。

## 2. Header 到底怎么渲染

这次用户指出 “header 像固定宽度，终端 resize 后展示不对”，这个判断是对的。

Claude Code 主要看两块：

- `claude-code/src/components/Messages.tsx`
- `claude-code/src/components/LogoV2/LogoV2.tsx`

结论：

- scrollback 模式下，欢迎 header 是消息流顶部的 `LogoHeader`。
- 它不是 ANSI 手工写死的面板，而是普通 React 组件。
- `LogoV2` 用 `useTerminalSize()` 直接读取终端列宽。
- 它会根据列宽切换 `horizontal` 和 `compact` 两种布局。
- 左侧 logo 区有自己的最大宽度，但整个 header 总宽度始终受当前终端列数约束。

这和当前 Dart 版的差异在于：

- Dart rich UI 之前多处使用 `min(console.windowWidth, 140)`。
- 这会把 header、transcript、prompt block 一起钉死在 `140` 列以内。
- resize 变宽时，Claude Code 会按新列宽重排；Dart 版只是在旧宽度里继续画。

本轮已先把 Dart 侧修正为：

- rich viewport 直接跟随当前终端宽度，不再固定 `140`
- 欢迎 header 在窄宽度下退化成单列布局
- 宽终端时继续保留双列，但列宽按内容和终端宽度动态计算

这只是第一步。更深一层的差异是：Claude Code 在 fullscreen 下其实不会一直固定欢迎 header，真正固定的是 sticky prompt header。

## 3. TS 版 TUI 的核心布局

主要文件：

- `claude-code/src/components/FullscreenLayout.tsx`
- `claude-code/src/ink/components/ScrollBox.js`
- `claude-code/src/components/PromptInput/PromptInput.tsx`
- `claude-code/src/components/PromptInput/PromptInputFooter.tsx`

`FullscreenLayout` 可以简化理解成三个层：

1. 上层 scrollable 区
   有 `ScrollBox`、sticky prompt header、new messages pill、浮动内容。
2. 下层 bottom 区
   固定底部，放 prompt input 和 footer。
3. 绝对定位 modal 区
   覆盖在底部之上，用于 slash dialog / permission dialog 等。

要点：

- transcript 是唯一主滚动区。
- bottom 区固定，不跟 transcript 一起滚。
- sticky header 和 new messages pill 都是 scroll state 派生的 chrome，不是 transcript 自己的一部分。

## 4. Scroll 和 Input 是分开的

### 4.1 主滚动区

`ScrollBox` 负责：

- `scrollTop`
- `scrollBy/scrollTo/scrollToBottom`
- sticky-to-bottom
- 视口裁剪
- 向外暴露订阅接口，让外层决定是否显示 sticky header / new pill

它不负责 prompt 编辑，也不负责 history。

### 4.2 输入区

输入区主要是：

- `PromptInput.tsx`
- `TextInput.tsx`
- `useTextInput.ts`
- `useArrowKeyHistory.tsx`

职责划分：

- `PromptInput`
  组织整体输入框、footer、suggestions、dialog、mode 切换。
- `TextInput/useTextInput`
  负责文本编辑、光标、换行、删除、多行上下移动。
- `useArrowKeyHistory`
  负责真正的输入 history 浏览。

最关键的行为：

- `Up/Down` 不是直接切 history。
- 先尝试在多行输入里移动光标。
- 只有没法继续移动时，才 fallback 到 history。

所以：

- history 只是输入编辑器的一个附属状态机
- 它不是 transcript scroll
- 更不应该由鼠标滚轮默认驱动

### 4.3 滚动事件传播

主要文件：

- `claude-code/src/components/ScrollKeybindingHandler.tsx`
- `claude-code/src/keybindings/defaultBindings.ts`

Claude Code 的滚动策略不是“事件来了就硬吃掉”，而是：

1. 优先让主滚动区处理。
2. 如果主滚动区根本没得滚，再把事件让给更深层组件。

这点很重要，因为它解释了为什么：

- wheel 默认滚 transcript
- modal 内部需要滚动时也能自己接管
- 输入 history 和滚动不会混成一个状态机

## 5. 等待态输入为什么还能继续工作

这是这次问题的核心。

关键文件：

- `claude-code/src/screens/REPL.tsx`
- `claude-code/src/components/PromptInput/PromptInput.tsx`
- `claude-code/src/hooks/useQueueProcessor.ts`
- `claude-code/src/utils/messageQueueManager.ts`
- `claude-code/src/utils/queueProcessor.ts`
- `claude-code/src/utils/QueryGuard.ts`
- `claude-code/src/hooks/useCancelRequest.ts`

### 5.1 PromptInput 没有被卸载

Claude Code 的模型不是：

1. 读一行输入
2. 阻塞执行 query
3. query 完成后再读下一行

而是：

1. `PromptInput` 常驻
2. 用户提交时，把输入送入执行链
3. query 在另一条异步链上运行
4. UI 根据状态持续重渲染

也就是说：

- 等待 LLM 时输入框还在
- `isLoading` 只影响 hint / spinner / 部分快捷键
- 输入组件本身并没有因为 query 运行而消失

### 5.2 新输入进入统一队列

Claude Code 有一个模块级统一命令队列。

见：

- `messageQueueManager.ts`
- `queueProcessor.ts`

特点：

- 队列不依赖 React state 保存
- 有明确优先级：`now > next > later`
- 用户新输入通常进 `next`
- 要立即打断当前任务的控制事件可以进 `now`
- 系统通知或后台消息可以进 `later`

所以等待态下用户继续输入的语义不是“修改当前请求”，而是：

1. 输入框继续接收输入
2. 提交后的新 prompt 进入队列
3. 当前 turn 结束或被 interrupt 后，再由 queue processor 接力处理

### 5.3 QueryGuard 防止并发串台

`QueryGuard` 只有三个状态：

- `idle`
- `dispatching`
- `running`

作用：

- 队列准备送命令时先 `reserve()`，进入 `dispatching`
- 真正开始 query 时 `tryStart()`，进入 `running`
- turn 完成后 `end()`，回到 `idle`
- interrupt 时 `forceEnd()`，直接让旧 generation 失效

它解决的问题是：

- 用户 interrupt 旧 turn 后，立刻又提交了新 turn
- 如果没有 generation guard，旧 finally 很容易把新的 loading 状态或消息顺序冲掉

### 5.4 interrupt 的优先级路由

`CancelRequestHandler` 不是简单地“按 Esc 或 Ctrl+C 就退出”。

它的优先级大致是：

1. 如果有正在运行的任务，先 interrupt 当前任务
2. 如果没有运行任务，但队列里有待处理命令，优先处理队列
3. 再没有，才进入别的关闭/退出逻辑

Esc 和 Ctrl+C 也不是同一个语义：

- Esc 更偏向 chat context 的 cancel
- Ctrl+C 走全局 interrupt
- 在 agent / teammate view 下，Ctrl+C 还会附带 stop agent / exit view

所以 Claude Code 的 interrupt 是一个明确的控制事件，不是把 stdin 里的 `^C` 粗暴当成“退出 REPL”。

### 5.5 UI 为什么能同时显示多条运行状态

因为状态源本来就是拆开的。

典型状态包括：

- `messages`
- `streamingText`
- `streamingToolUses`
- `tasks`
- `queuedCommands`
- `toolUseConfirmQueue`
- `abortController`
- `AppState` 里的 footer / overlay / teammate 状态

这些状态来自不同子系统：

- query 主链
- tool / permission 子链
- agent / teammate 子链
- queue / interrupt 子链

UI 层只负责订阅和组合显示。

所以用户看到的是：

- 当前前景 turn 在跑
- 后台 agent 也在跑
- 输入框仍然可编辑
- queued prompt 也能挂着
- interrupt 事件随时可打断当前 turn

这正是用户这次说的“多层、异步任务，保证各个任务运行同时，UI 层能实时展示运行状态”。

## 6. 当前 Dart 实现和 Claude Code 的关键错位

主要文件：

- `lib/src/cli/runner.dart`

当前 Dart rich REPL 的结构更像：

1. 固定欢迎 header
2. transcript viewport
3. 固定 status
4. 固定 message composer

但它和 Claude Code 至少有五个关键错位。

### 6.1 错位一：header 宽度与语义都不对

之前 Dart rich UI 多处使用 `min(console.windowWidth, 140)`：

- 欢迎 header
- transcript 区
- scrollback prompt block
- fullscreen render

问题：

- 这会让宽终端下的 UI 永远停留在 `140` 宽以内
- resize 后观感不像 Claude Code
- 欢迎 header 还是永久固定的 dashboard 语义

Claude Code 的特点是：

- header 宽度直接跟终端列宽走
- fullscreen 顶部固定的是 sticky prompt header，不是欢迎 header

### 6.2 错位二：滚轮语义不对

当前 Dart 在 `_readRichCsiSequence()` 里把鼠标 wheel 直接变成 transcript scroll action。

虽然本轮已经是按行滚动而不是整页滚动，但从结构上仍然存在问题：

- 滚轮事件还是在输入读取链里被解释
- 没有独立的 scroll controller
- 也没有“主滚动区先处理，处理不了再让给子组件”的事件路由

### 6.3 错位三：页面滚动和输入编辑共享一个输入循环

当前 `_readRichInput()` 里同时处理：

- 光标移动
- 输入编辑
- history 浏览
- transcript scroll

即便键位上区分了：

- `Up/Down` 先移动光标，再 fallback history
- wheel / pageUp / pageDown 走 transcript scroll

但本质上它们仍然共享一个同步读取循环。

Claude Code 不是这样：

- `ScrollBox` 处理 scroll
- `TextInput/useTextInput` 处理编辑
- `useArrowKeyHistory` 处理 history
- `useQueueProcessor` 处理 queued input

这是分层的，不是一个 while-loop 把所有事情都做完。

### 6.4 错位四：没有 sticky header / new messages pill

当前 Dart 只有：

- 固定欢迎 header
- transcript viewport
- status line

缺少 Claude Code 里两个真正重要的滚动反馈：

- sticky prompt header
- new messages pill / jump to bottom

所以用户会感觉“你没有真的理解 claude code 的 UI 层”。

### 6.5 错位五：提交后 turn 执行阻塞输入

这是最大的问题。

当前 Dart rich REPL 的主循环是：

1. `_promptRichInput()`
2. 拿到完整输入
3. `await _runReplTurnCollectStream(...)`
4. turn 完成后再回到下一次 `_promptRichInput()`

这意味着：

- streaming 时输入框虽然还能被画出来
- 但那个输入框只是“显示出来了”
- 实际上用户不能继续输入
- 也不存在 queued input
- interrupt 只能依赖当前 turn 内部的 `sigint` 监听

Claude Code 则是：

- 输入组件常驻
- turn 是后台异步任务
- 等待态仍能继续输入
- 新输入进入队列
- interrupt 和 queued input 通过独立状态机接力

这不是小 bug，而是 runner 主循环模型不同。

## 7. 对 Dart 的后续改造建议

不要继续把行为堆在 `_readRichInput()` 上。建议拆成四层。

### 7.1 RichReplState

先把这些状态提成独立对象：

- transcript
- draft input
- cursor
- status
- queued prompts
- running turn handle
- interrupt state
- scroll state

### 7.2 Input Controller

把“读按键并更新 draft”的逻辑独立出来，不再和 turn 执行函数共享控制流。

目标：

- waiting 时输入仍然可编辑
- Enter 在 loading 时不是丢掉，而是 enqueue
- Esc / Ctrl+C 可以先走 interrupt，再决定是否清草稿或退出

### 7.3 Turn Runner

把当前 `_runReplTurnCollectStream()` 外面再包一层 Rich turn worker：

- start turn
- 持有 abort handle
- 持续写 transcript delta
- turn 结束后自动检查队列

也就是做一个最小版的：

- `QueryGuard`
- turn generation
- queued prompt processor
- interrupt bridge

### 7.4 Render Layer

渲染层只吃状态：

- fullscreen render
- scrollback prompt block
- sticky header
- jump-to-bottom
- queued prompt indicator

不要再让 render 逻辑决定输入控制流。

## 8. 建议的实现顺序

### 阶段 1：纠正宽度和基础语义

目标：

- rich viewport 宽度跟终端列宽走
- 欢迎 header 在窄终端下退化成单列
- 去掉“固定 140 宽”的硬编码

这一步本轮已经开始做了。

### 阶段 2：拆分 scroll 和 input

目标：

- transcript scroll state 独立
- wheel 只作用于 transcript scroll
- `Up/Down` 保持“先光标移动，再 history fallback”

### 阶段 3：补 scroll chrome

目标：

- sticky prompt header
- jump-to-bottom / new messages pill

### 阶段 4：把等待态输入改成真正的前台输入 + 后台 turn

这是体验上的决定性阶段。

目标：

- streaming 时底部输入框继续可编辑
- 新 prompt 默认排队，不抢占当前 turn
- Esc / Ctrl+C 可以 interrupt 当前任务
- interrupt 后自动尝试消费排队输入

如果这一步不做，UI 只能“看起来像 Claude Code”，不会“工作起来像 Claude Code”。

## 9. 对 Dart 改造的直接约束

后面改 Dart 代码时，至少遵守这些约束：

1. fullscreen 下不再把欢迎 header 当成永久固定 chrome
2. 整个可读内容区只有一个主 transcript viewport
3. 鼠标滚轮默认只驱动 transcript scroll
4. 输入 history 只由键盘 history 逻辑驱动，不由鼠标滚轮驱动
5. `Up/Down` 必须继续保留“先光标移动，再 history fallback”
6. status/footer/input 属于底部固定区，不参与 transcript 滚动
7. waiting 时输入组件不能被 turn 执行链阻塞
8. queued input、interrupt、turn completion 必须有明确状态机，而不是靠 print 顺序隐式表达

## 10. 本轮结论

这次问题不是简单 bug，而是 Dart rich REPL 目前的职责划分从一开始就和 Claude Code 的 TUI / 任务流模型不一致。

本轮先做的修正是：

- rich header 宽度和布局按终端大小自适应
- 不再把 rich viewport 宽度写死在 `140`
- 文档上把 Claude Code 的 header、输入、队列、取消、任务流补齐

而真正决定体验上限的，是下一步把 Dart REPL 从“阻塞式读输入”改成“前台输入 + 后台 turn + queue + interrupt”的结构。
