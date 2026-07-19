# CodexBar 一手资料研究与 Codex Pulse 可复用结论

> 研究对象：[`steipete/CodexBar`](https://github.com/steipete/CodexBar)  
> 固定源码基线：[`2ccb4525687c92ff1cd50c8c57f24420c1fcb71f`](https://github.com/steipete/CodexBar/tree/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f)  
> 研究日期：2026-07-18  
> 资料范围：只使用上游 README、上游文档、上游源代码、测试和发布资料；没有使用第三方评测或二手解读。

## 结论摘要

CodexBar 最值得 Codex Pulse 学习的不是它的功能数量，而是四个工程原则：

1. **把采集策略与展示隔离**：CodexBar 用 descriptor、fetch strategy、统一 snapshot 和 store 把多种采集方式收敛到稳定输出；Codex Pulse 应把这个思想缩小为“只读本地数据源能力描述 + 指标级观察值 + `StatusSnapshot`”。
2. **以语义和可用性建模，而不是相信字段位置**：CodexBar 显式表示窗口时长、未知用量、合成占位和数据置信度；Codex Pulse 应继续以 `window_minutes == 10080` 识别 weekly，并让每个字段携带独立的新鲜度、来源和可用状态。
3. **把刷新决策做成纯策略，把副作用放在边缘**：CodexBar 的自适应刷新策略是纯函数，并在 store 层合并并发刷新；Codex Pulse 可采用“任务活动时 500 ms、空闲时事件驱动、生命周期停止时零观察”的三档调度。
4. **把菜单栏状态项当作会失效的系统资源**：CodexBar 对保存位置异常、状态项未 materialize、屏幕切换和 macOS 26 菜单栏许可做了证据化检查、有限恢复和用户指引。这一设计直接对应 Codex Pulse 已出现的“图标没出现 / 拖动后消失”问题，优先级应为 P0。

不应复制 CodexBar 的产品范围。CodexBar 是多 provider、账号/凭证/网络/CLI/Widget/更新/通知平台；Codex Pulse 的优势恰恰是单一 Codex、任务级实时性、严格只读、无凭证、无网络、无内容持久化。

## 1. CodexBar 的 Mission 与产品定位

CodexBar 的一句话使命是“把所有 AI coding limit 放进菜单栏”。上游 README 明确把它定位为 macOS 14+ 的多 provider 额度与重置时间工具，可按 provider 拆分状态项或合并图标，并强调无 Dock 图标和低干扰 UI（[README L1-L23](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/README.md#L1-L23)）。

它解决的是“跨 provider 配额可见性”问题，核心用户价值包括：

- 看到 session、weekly、monthly 等窗口与重置时间；
- 看到额度、消费和本地 cost scan；
- 轮询 provider status 并显示事故标记；
- 在菜单栏、菜单、Widget 和 CLI 中复用同一批 usage 数据（[README L140-L161](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/README.md#L140-L161)）。

CodexBar 所称的 privacy-first 是“尽量复用已有 session，不保存密码，并默认在设备上解析”；它仍会按功能读取 OAuth、API Key、Cookie、Keychain、本地文件，部分 provider 还会访问网络（[README L23](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/README.md#L23)、[README L163-L184](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/README.md#L163-L184)）。因此，它与 Codex Pulse 的“禁止读取凭证、禁止网络、禁止内容持久化”不是同一隐私边界。

## 2. CodexBar 的 Architecture

### 2.1 模块和数据流

上游架构文档把系统拆成：

- `CodexBarCore`：抓取、解析、provider probe 和共享模型；
- `CodexBar`：`UsageStore`、设置、状态项、菜单和图标；
- `CodexBarWidget`：消费共享 snapshot；
- `CodexBarCLI`：输出 usage/status；
- 若干 provider helper 进程。

主数据流是：

```text
后台刷新 → UsageFetcher / provider probes → UsageStore → 菜单 / 图标 / Widget
设置 → SettingsStore → UsageStore 的刷新节奏与功能开关
```

来源：[架构文档 L10-L28](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/architecture.md#L10-L28)。SwiftPM target 也落实了 Core、App、CLI、Widget 和测试边界，并开启 strict concurrency（[`Package.swift` L22-L40、L64-L85、L154-L196](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Package.swift#L22-L40)）。

### 2.2 Descriptor + Fetch Strategy

CodexBar 将 provider 的名称、品牌、能力、fetch plan 和 CLI 信息集中到 `ProviderDescriptor`，用穷举 registry 在启动期校验注册完整性（[`ProviderDescriptor.swift` L13-L45、L47-L126](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/Providers/ProviderDescriptor.swift#L13-L45)）。

每个 `ProviderFetchStrategy` 明确：

- 稳定 ID 与类型；
- 当前是否可用；
- 如何 fetch；
- 哪些错误允许进入下一个 fallback。

pipeline 顺序执行策略，检查取消，记录每次 attempt 的可用性与错误，并返回统一 outcome（[`ProviderFetchPlan.swift` L183-L278](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift#L183-L278)）。上游 authoring guide 进一步要求 host API 小而可测，provider 不应随意直接访问文件系统、Keychain 或浏览器内部（[`docs/provider.md` L60-L84](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/provider.md#L60-L84)）。

### 2.3 Snapshot 与 rate-limit 语义

CodexBar 的 `RateWindow` 保存 `usedPercent`、`windowMinutes`、reset 信息和 `isSyntheticPlaceholder`；`NamedRateWindow` 额外用 `usageKnown` 区分“知道是 0”与“不知道用量”；`UsageSnapshot` 再统一承载窗口、更新时间、身份和置信度（[`UsageFetcher.swift` L3-L92](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/UsageFetcher.swift#L3-L92)、[`UsageFetcher.swift` L96-L139](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/UsageFetcher.swift#L96-L139)、[`UsageFetcher.swift` L182-L225](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/UsageFetcher.swift#L182-L225)）。

Codex 窗口归一化不是简单相信 `primary/secondary` 位置，而是用 300 分钟识别 session、10080 分钟识别 weekly，并在位置颠倒或只返回一个窗口时重新归位（[`CodexRateWindowNormalizer.swift` L3-L59](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/Providers/Codex/CodexRateWindowNormalizer.swift#L3-L59)）。这与 Codex Pulse PRD 的 weekly 规则一致。

### 2.4 Codex CLI 与 session 能力

CodexBar 可启动 `codex -s read-only -a untrusted app-server`，通过 `account/rateLimits/read` 和 `account/read` 获取配额与账号信息，并对超时、输出大小和子进程生命周期设边界（[`docs/codex.md` L102-L126](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/codex.md#L102-L126)、[`UsageFetcher.swift` L1092-L1121](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/UsageFetcher.swift#L1092-L1121)、[`UsageFetcher.swift` L1252-L1325](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/UsageFetcher.swift#L1252-L1325)）。

它也能扫描本地 agent session，但 agent-aware 路径会在用户同意后运行 `ps`、`lsof` 并读取已知 session 元数据，且对进程数、候选文件、目录深度和耗时设上限（[`refresh-loop.md` L47-L64](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/refresh-loop.md#L47-L64)）。`CodexThreadMetadataReader` 会发现版本最高的 `state_*.sqlite`，只读打开 SQLite、设置 100 ms busy timeout，并为 schema 差异准备两条查询（[`CodexThreadMetadataReader.swift` L18-L97](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBarCore/CodexThreadMetadataReader.swift#L18-L97)）。

其中只有“有界扫描、版本发现、只读短查询、schema fallback”适合 Codex Pulse；`ps`/`lsof` 生命周期判断和 CLI 子进程不适合当前边界。

### 2.5 刷新、合并与降级

CodexBar 将 adaptive refresh 写成纯函数：输入最近交互、最近活动、低电量和热状态，输出下一次延迟及稳定 reason；真实时间和 `ProcessInfo` 由 store 在调用边缘采集。刷新只允许一个 provider batch 同时运行，stale/error 在 UI 中显式呈现（[`refresh-loop.md` L18-L46、L65-L72](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/refresh-loop.md#L18-L46)）。

这个结构可复用，但 Codex Pulse 不能照搬 2–30 分钟 cadence，因为 PRD 要求活动生成每 500 ms 有机会更新且 P95 不超过 750 ms。适配方式应是保留“纯策略 + 单飞合并”，重新定义为生命周期/活动度驱动。

### 2.6 菜单栏状态项韧性

CodexBar 为每类状态项设置稳定 `autosaveName`，创建前检查 macOS 保存的 `NSStatusItem Preferred Position`；无效、非数值、非正或远超当前屏幕范围的位置会被清理（[`StatusItemController.swift` L52-L73、L305-L329](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBar/StatusItemController.swift#L52-L73)、[`MenuBarStatusItemPlacementPreflight.swift` L4-L55](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBar/MenuBarStatusItemPlacementPreflight.swift#L4-L55)）。

它把状态项健康度建模为 `isVisible`、button/window/screen 是否存在、是否仍在当前屏幕、button width 等可观察证据，并区分 blocked 与 displaced（[`MenuBarVisibilityWatcher.swift` L4-L124](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBar/MenuBarVisibilityWatcher.swift#L4-L124)）。启动 2 秒后检查，必要时有限重建；屏幕配置变化时先判断刷新现有 item 还是重建，并避免无限重建破坏 Control Center；macOS 26 仍阻止显示时，引导用户打开 Menu Bar 设置（[`MenuBarVisibilityWatcher.swift` L245-L309](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBar/MenuBarVisibilityWatcher.swift#L245-L309)、[`MenuBarVisibilityWatcher.swift` L311-L423](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Sources/CodexBar/MenuBarVisibilityWatcher.swift#L311-L423)）。

这是本次研究中对 Codex Pulse 最直接、确定性最高的整改来源。

### 2.7 更新和测试

CodexBar 使用 Sparkle、签名 appcast、stable/beta channel，并只在受支持的签名安装来源启用；Homebrew 和 unsigned build 禁用 Sparkle（[`docs/sparkle.md` L9-L29](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/sparkle.md#L9-L29)）。这是一套合理的公开分发方案，但 Codex Pulse PRD 明确排除公开分发和自动更新，因此不应引入。

CodexBar 将 parser/snapshot mapping、strategy availability/fallback、CLI 行为和状态项恢复都纳入测试；开发流程要求测试后再打包重启（[`docs/provider.md` L179-L207](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/provider.md#L179-L207)、[`docs/DEVELOPMENT.md` L11-L32](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/DEVELOPMENT.md#L11-L32)）。菜单栏恢复规则有专门的纯数据测试，覆盖 blocked、displaced、startup recovery 和 screen change（[`MenuBarVisibilityWatcherTests.swift`](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/Tests/CodexBarTests/MenuBarVisibilityWatcherTests.swift)）。

## 3. 对 Codex Pulse Mission 的整改建议

### 3.1 建议 Mission

> **Codex Pulse 是一个只在 Codex 运行期间存在的、本地只读、隐私封闭的 macOS 菜单栏任务遥测伴侣。它把 weekly 余量、当前主会话的实时模型输出速度、模型和上下文余量，压缩为无需切换窗口即可理解的可信状态；当证据不足时明确显示未知，而不是推测或借用其他数据。**

### 3.2 为什么这样改

当前“实现个人自用菜单栏伴侣”的 Mission 描述了交付物，却没有定义产品必须优化的结果。建议的新 Mission 明确了五项不可互换的价值：

1. **生命周期受 Codex 约束**：Codex 未运行时不占菜单栏；
2. **任务级而非账户级**：模型、速度、上下文必须对应被选中的主会话；
3. **可信优先于覆盖率**：字段缺失显示 `—`，不能以其他窗口或其他会话补位；
4. **隐私封闭**：无凭证、无网络、无内容持久化；
5. **低干扰可见性**：状态栏是产品主界面，状态项可达性属于核心功能而非 UI 细节。

这保留了 CodexBar“让关键额度持续可见”的产品洞察，但拒绝把 Codex Pulse扩张成多 provider 额度平台。

### 3.3 Mission 的验收指标

建议在 PRD/AGENTS 的 Mission 后补充四个可测结果：

- **正确归属**：自动跟随或固定会话下，四项状态不跨会话混用；
- **新鲜度**：活动任务的可观察流事件到状态栏 P95 ≤ 750 ms；
- **可达性**：Codex 运行时，状态项在启动、Command 拖动和屏幕切换后仍可访问，或明确给出系统设置修复路径；
- **隐私证明**：自动测试/静态检查证明没有打开凭证文件、没有网络依赖、没有内容落盘。

## 4. 对 Codex Pulse Architecture 的整改建议

### 4.1 目标数据流

```text
NSWorkspace 生命周期事件
          │
          ▼
ObservationCoordinator ── 启停/合并/调度 ───────────────┐
          │                                               │
          ├── SessionJSONLTailer ─┐                       │
          ├── StateSQLiteProbe ───┼→ NormalizedObservation│
          └── LogSQLiteProbe ─────┘                       │
                                  ▼                       │
                         SessionResolver                  │
                                  ▼                       │
                           MetricsEngine                  │
                                  ▼                       │
                         SnapshotAssembler                │
                                  ▼                       │
                  immutable StatusSnapshotStore          │
                                  ▼                       │
             MenuBarPresenter + StatusItemHealthMonitor ◄┘
```

单向依赖仍保持 PRD 的“只读数据源 → 解析/计算 → `StatusSnapshot` → 展示”，但增加三个现在容易混在一起的边界：`NormalizedObservation`、`ObservationCoordinator` 和 `StatusItemHealthMonitor`。

### 4.2 模块整改

#### A. `CodexSourceDescriptor` / `SourcePipeline`

不要引入多 provider 抽象；借鉴 CodexBar descriptor，将对象缩小为 Codex 本地数据源：

```swift
struct CodexSourceDescriptor {
    let id: SourceID
    let capabilities: Set<Capability>
    let allowedPathKinds: Set<AllowedPathKind>
    let priority: Int
    let probe: @Sendable (...) async -> SourceProbeResult
}
```

能力至少包括 `weekly`、`sessionIndex`、`taskEvents`、`streamDeltas`、`formalTokenCounts`、`model`、`contextWindow`。pipeline 只在同一指标内按证据优先级选择来源，并记录 attempt 的结构化错误；禁止添加 OAuth、CLI、Cookie、Keychain、HTTP strategy。

收益：schema 或文件名变化时，某个 probe 降级不会把全部指标一起打成不可用；同时能明确回答“这个值来自哪里、何时更新、为何未知”。

#### B. `NormalizedObservation`

数据源 adapter 不直接组装最终 `StatusSnapshot`，而是输出不含 UI 文本的领域事件，例如：

- `weeklyWindow(limitID, windowMinutes, usedPercent, resetsAt, observedAt)`；
- `taskTransition(sessionID, taskID, stage, observedAt)`；
- `streamDelta(sessionID, responseID, kind, transientTokenCount, observedAt)`；
- `formalTokenCount(sessionID, responseID, input, output, reasoningOutput, contextWindow, observedAt)`；
- `sessionMetadata(sessionID, visibility, parentID, title, model, observedAt)`。

原始 delta 只在 adapter/分词器调用栈内存在；`NormalizedObservation` 只能保存计数，不得携带文本或工具内容。

收益：隐私边界成为类型边界，也让 JSONL、SQLite 和未来 schema adapter 共享同一组行为测试。

#### C. `MetricValue<T>` 与 `SnapshotAssembler`

参考 CodexBar 的 `usageKnown`、placeholder 和 confidence，但按 Codex Pulse 的字段独立降级要求，建议每项指标使用：

```swift
enum Availability { case available, stale, unavailable }

struct MetricValue<T> {
    let value: T?
    let availability: Availability
    let observedAt: Date?
    let source: SourceID?
    let confidence: Confidence
    let errorCode: MetricErrorCode?
}
```

`StatusSnapshot` 继续作为唯一 UI 输入；`SnapshotAssembler` 决定 unknown/stale 的显示语义，UI 不读取数据库、不做 fallback、不计算 weekly/session 归属。

收益：避免把 `nil` 同时解释成“从未见过、暂时读失败、过期、固定会话失效、真的没有活动”等多种状态。

#### D. `ObservationCoordinator` 与纯刷新策略

借鉴 CodexBar 的 pure policy + single-flight，但使用 Codex Pulse 专用状态：

| 状态 | 观察策略 |
| --- | --- |
| Codex 未运行 | 全部 adapter 停止，释放 session/delta 内存 |
| Codex 运行且空闲 | 文件系统事件驱动；weekly/索引只在相关文件变化时短查询 |
| 当前主任务活动 | 流式源增量读取；500 ms 聚合并发布，2 秒滑动窗口 |
| 数据源轮转/失效 | 退避后重新发现；不忙循环、不全量重复扫描 |

coordinator 合并同一时刻的更新，禁止重入 scan；所有 timer、file event stream、SQLite connection 和 task 都有明确 owner，并在 Codex 退出或 `CODEX_HOME` 切换时取消。

#### E. `StatusItemHealthMonitor`（P0）

建议直接把状态项“存在”和“可达”分开建模：

- 稳定 autosave identity；
- 创建前只清理明显越界/损坏的 preferred-position 值，不清理合法用户排序；
- 启动后 2 秒采集 `isVisible/button/window/screen/width` 证据；
- 屏幕参数变化后延迟复核；
- 先切换 `isVisible` 刷新现有 item，只有 blocked 才有限重建；
- macOS 26 若系统菜单栏许可阻止显示，展示一次带“打开菜单栏设置”的说明；
- 恢复次数严格有上限，避免循环销毁状态项；
- 记录的诊断只能包含布尔状态、尺寸、屏幕计数、错误码，不含路径或会话内容。

这比“发现隐藏就设回 `isVisible = true`”更可靠，也不会用更换 Bundle ID 掩盖持久状态问题。

#### F. Core / App 并发边界

- `CodexPulseCore` 保持 Foundation/SQLite 可测试逻辑，不依赖 AppKit；
- AppKit/SwiftUI 只在 `CodexPulseApp`；
- adapter/coordinator 使用 actor 或明确串行 executor 管理游标与 inode 状态；
- 跨边界模型遵守 `Sendable`；只有 presenter 和 `NSStatusItem` 在 `MainActor`；
- 不为个人自用 MVP 增加 CLI、Widget、HTTP server 或 helper 进程。

### 4.3 测试整改

在现有 `StatusSnapshot` 高层测试缝之外，增加以下确定性测试：

1. **Source pipeline**：能力缺失、schema 不匹配、SQLite busy、一个 adapter 失败时其他指标继续更新；
2. **隐私类型测试**：`NormalizedObservation` 不存在承载原始文本、Cookie、token 或工具结果的字段；
3. **单飞与取消**：Codex 退出、`CODEX_HOME` 切换、日志轮转后旧任务和旧游标不能继续发布；
4. **状态项纯规则测试**：blocked、displaced、合法隐藏、异常 preferred position、启动恢复、屏幕切换恢复、恢复次数上限；
5. **真实 macOS 冒烟**：Command 拖动排序、系统设置隐藏/恢复、外接屏接入/拔出、浅/深色和 macOS 26 allow-list。

不建议复制 CodexBar 的大规模 provider 单测数量；只保留与 Codex Pulse Mission 和 PRD acceptance criteria 直接相连的行为测试。

## 5. 明确不采用的 CodexBar 设计

| CodexBar 能力 | 不采用原因 |
| --- | --- |
| OAuth API、读取/刷新 `auth.json` | Codex Pulse 明确禁止读取凭证；CodexBar 的 Codex 默认路径会读取 OAuth token（[`docs/codex.md` L18-L38](https://github.com/steipete/CodexBar/blob/2ccb4525687c92ff1cd50c8c57f24420c1fcb71f/docs/codex.md#L18-L38)） |
| `codex app-server` / PTY / CLI fallback | 会启动额外进程并扩大边界；Pulse 已有本地只读数据源，且 PRD 不授权 CLI 交互 |
| 浏览器 Cookie、Keychain、WebView scrape、HTTP provider API | 违反无凭证、无网络边界 |
| `ps`/`lsof` agent-aware session scanner | AGENTS 明确禁止通过进程轮询判断 Codex 生命周期 |
| Accessibility window focus / UI 自动化 | 与禁止辅助功能注入/UI 自动化冲突 |
| 持久化 cost/session cache | Pulse 禁止形成第二份会话内容或历史分析；仅允许偏好持久化 |
| 多 provider registry、账号切换、CLI、Widget、localhost server | 偏离单一 Codex、个人自用、菜单栏任务遥测 Mission |
| 通知、confetti、事故状态、云端 status polling | PRD 明确排除通知，并禁止网络 |
| Sparkle、Homebrew、公证发布流水线 | PRD 明确排除公开分发和自动更新；当前阶段收益不足以覆盖边界和依赖成本 |

## 6. 有把握实施的整改顺序

### P0：状态项可靠性

1. 引入稳定 status-item identity 与 preferred-position preflight；
2. 引入纯数据的 health snapshot / recovery policy；
3. 启动和屏幕变化时有限恢复；
4. 加 macOS 26 设置引导；
5. 单测 + 真实拖动/屏幕冒烟。

这是独立于数据层的改动，范围清晰，且直接修复已经复现的可达性问题。

### P1：指标级来源与可用性

1. 定义 `NormalizedObservation` 和 `MetricValue<T>`；
2. 将 JSONL、state SQLite、logs SQLite adapter 改为只输出 observation；
3. `SnapshotAssembler` 统一字段独立降级、freshness 和 source provenance；
4. 用现有脱敏 fixture 回归所有 PRD 指标。

这不会改变用户可见格式，只会提高错误隔离和调试确定性。

### P2：观察协调与性能

1. 把 500 ms UI tick 改为活动任务期间的聚合发布；
2. 空闲依赖文件事件，不重复全量遍历；
3. 实现 single-flight、debounce、取消和轮转重发现；
4. 增加 CPU、延迟和长时间运行测试。

### P3：文档与隐私证明

1. 用本文建议改写 Mission；
2. 在架构文档固化模块依赖和禁止能力；
3. 将隐私 checklist 变成测试/构建检查；
4. 保持自动更新、网络 provider 和公开分发为 Out of Scope。

## 7. 最终判断

CodexBar 证明了菜单栏额度工具在三处最容易变复杂：**数据源差异、状态/降级语义、状态项系统行为**。Codex Pulse 不需要继承它的平台规模，但应该继承它的边界意识：采集策略可替换、快照稳定、刷新可证明、状态项可恢复。

本研究建议的整改均能在现有 Swift/SwiftUI/AppKit、`CodexPulseCore`/`CodexPulseApp` 和脱敏 fixture 体系内实现，不要求新增网络、凭证、第三方运行时或产品范围；其中 P0 和 P1 对当前项目有明确正向收益且风险可控。
