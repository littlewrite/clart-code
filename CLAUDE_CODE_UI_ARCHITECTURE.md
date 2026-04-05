# Claude Code UI 架构分析

## 核心架构概述

Claude Code 使用基于 Ink 的 React-like 框架构建终端 UI，具有以下关键特点：

### 1. 屏幕管理
- **Alternate Screen Buffer**: 使用 DEC 1049 序列 (`\x1b[?1049h` 和 `\x1b[?1049l`) 切换主屏幕和备用屏幕
- **目的**: 保护主屏幕的历史滚动内容，在备用屏幕中进行全屏 UI 渲染
- **实现**: `AlternateScreen` 组件 (`src/ink/components/AlternateScreen.tsx`)

### 2. 滚动系统
- **ScrollBox 组件**: 虚拟滚动容器，支持增量渲染和视口裁剪
- **关键特性**:
  - `stickyScroll`: 自动滚动到底部
  - 虚拟滚动: 只渲染可见区域的内容
  - 键盘/鼠标滚动事件处理
- **实现**: `ScrollBox` 组件 (`src/ink/components/ScrollBox.tsx`)

### 3. 渲染机制
- **增量渲染**: 只更新变化的 UI 部分，避免全屏刷新
- **渲染器**: `createRenderer` (`src/ink/renderer.ts`)
- **Alt Screen 特殊处理**:
  - `altScreen: boolean` 参数控制渲染行为
  - 高度限制: `height = options.altScreen ? terminalRows : yogaHeight`
  - 视口高度: `height: options.altScreen ? terminalRows + 1 : terminalRows`

### 4. 布局结构
```
AlternateScreen (全屏模式)
├── Box (height={terminalRows}, flexShrink=0)
│   ├── FullscreenLayout
│   │   ├── ScrollBox (滚动区域)
│   │   │   ├── 消息列表 (虚拟滚动)
│   │   │   └── 固定底部元素
│   │   └── 覆盖层 (模态框等)
│   └── 其他组件
```

## 关键差异: TypeScript vs Dart 实现

### TypeScript (Claude Code) 实现
1. **React-like 组件模型**: 使用 Ink 框架，基于虚拟 DOM
2. **增量渲染**: 只更新变化的部分
3. **虚拟滚动**: ScrollBox 组件只渲染可见区域
4. **Alternate Screen**: 通过 `AlternateScreen` 组件管理
5. **事件处理**: 使用 `useInput` 和 `useStdin` 处理键盘/鼠标事件

### Dart (当前实现) 问题
1. **全屏刷新**: 每次渲染都调用 `console.clearScreen()`，导致整个屏幕重绘
2. **无虚拟滚动**: 渲染所有消息，无论是否可见
3. **无 Alternate Screen 管理**: 手动添加 ANSI 序列，但缺少完整的屏幕管理
4. **事件处理**: 直接处理 stdin，缺少 React 式的组件化事件系统

## 问题分析

### 1. 滚动问题
**现象**: 鼠标滚动导致切换历史输入内容

**原因**: Dart 实现中没有区分内容滚动和命令历史切换。在 TypeScript 中：
- `ScrollKeybindingHandler` 处理滚动事件
- `useInput` 和 `useStdin` 分离不同的事件处理
- 滚动事件被 `ScrollBox` 捕获，不会触发命令历史切换

### 2. Header 固定问题
**现象**: Header 变为固定，无法滚动

**原因**: 在 TypeScript 中，Header 是 `ScrollBox` 外部的内容，而消息区域在 `ScrollBox` 内部。Dart 实现将整个 UI 放在一个固定布局中。

### 3. 屏幕刷新问题
**现象**: 屏幕刷新感觉奇怪

**原因**: `console.clearScreen()` 导致全屏刷新，而 TypeScript 使用增量渲染

## 解决方案建议

### 短期方案 (快速修复)
1. **禁用鼠标滚动**: 在 Dart 中暂时禁用鼠标滚动事件
2. **改进渲染**: 减少不必要的 `clearScreen()` 调用
3. **优化布局**: 修复 Header 和输入框的布局

### 长期方案 (完整重构)
1. **实现虚拟滚动系统**: 类似 `ScrollBox` 的组件
2. **实现增量渲染**: 只更新变化的行
3. **完整的 Alternate Screen 管理**: 集成到渲染管道中
4. **事件处理系统**: 分离滚动事件和命令历史事件

## 当前 Dart 实现的关键缺失

1. **虚拟 DOM/组件系统**: Ink 提供 React-like 的组件模型
2. **增量渲染**: `renderNodeToOutput` 只更新变化的部分
3. **布局引擎**: Yoga 布局引擎计算组件位置
4. **事件冒泡/捕获**: React 式的事件系统
5. **状态管理**: 组件状态和生命周期

## 测试建议

1. **验证 Alternate Screen**: 确保 ANSI 序列正确工作
2. **测试鼠标事件**: 区分滚动和命令历史
3. **性能测试**: 比较全屏刷新 vs 增量渲染
4. **布局测试**: 验证固定 Header 和可滚动区域的分离

## 参考文件

- `claudecode/src/screens/REPL.tsx` - 主 UI 组件
- `claudecode/src/ink/components/AlternateScreen.tsx` - Alternate Screen 组件
- `claudecode/src/ink/components/ScrollBox.tsx` - 滚动容器
- `claudecode/src/ink/renderer.ts` - 渲染器实现
- `claudecode/src/ink/termio/dec.ts` - ANSI 序列定义