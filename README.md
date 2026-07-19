# Codex Pulse 2

Codex Pulse 2 是个人自用的 macOS 菜单栏伴侣应用。它作为本地只读观察者，在空闲时显示 weekly 余量，在任务进行中显示实时 token 速度、模型和上下文可用比例。

完整产品定义见 [PRD](docs/PRD-codex-pulse.md)。

## 当前能力

- 识别 Bundle ID 为 `com.openai.codex` 的 ChatGPT/Codex Desktop。
- 空闲显示 `W <weekly 剩余百分比>`。
- 活动任务显示 weekly、实时/最终 token 速度、模型和上下文比例。
- 自动排除自动审查与子代理线程，支持固定会话和恢复自动跟随。
- `动态图标显示`、悬停详情、右键设置和 `CODEX_HOME` 选择。
- 白色到橙色的 12 色标连续着色。
- Codex 启停联动，以及可关闭的登录启动监视器。
- Version 2 使用后台 actor、文件事件与 single-flight 刷新；空闲时不再每 500 ms 扫描数据源。
- JSONL、状态数据库与响应日志经统一 Repository 生成同一批次的 `PulseState`。
- 指标独立记录可用性与来源；不兼容的最新数据库会回退到较旧的兼容版本。
- 状态项具有稳定身份、位置预检、屏幕变化复核和有限恢复，降低 Command 拖动后消失的概率。
- 不读取凭证、不写回 Codex、不上传或持久化会话内容。

## 构建

本机需要 Swift Command Line Tools。运行：

```bash
make build
```

构建会先运行行为测试，再生成：

```text
dist/Codex Pulse.app
```

## 使用

1. 构建后，将 `dist/Codex Pulse.app` 拖到 `/Applications`，或直接双击运行。
2. 保持 ChatGPT/Codex Desktop 正在运行；Codex Pulse 会出现在菜单栏。
3. 首次运行默认读取 `~/.codex`，可从右键菜单选择其他 `CODEX_HOME`。
4. 默认开启“随 Codex 启动”。若 macOS 提示登录项审批，请在“系统设置 → 通用 → 登录项”允许 Codex Pulse Monitor。
5. 按住 `Command` 可拖动菜单栏项目调整位置。

## 验证

仅运行行为测试：

```bash
make test
```

测试使用临时、脱敏的 `CODEX_HOME` 夹具，不读取真实会话或凭证。
