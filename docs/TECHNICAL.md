# TokenMeter Technical Notes

TokenMeter combines two very different quota surfaces:

- Claude Code exposes official usage through Anthropic inference response headers.
- Codex currently exposes useful rate-limit snapshots only as local websocket log events.

The app keeps those sources separate and labels Codex freshness explicitly.

---

## 1. Architecture

TokenMeter is a single-file native macOS app (`main.swift`) built with AppKit + SwiftUI:

```text
NSStatusItem
  -> compact menu title: Cl 9% · ~Cx 59%
  -> click opens FloatingPanel

AppDelegate
  -> data timer, every 120s
       ClaudeFetcher.fetch()
       CodexFetcher.fetch()
       Fetcher.fetchTasks()
  -> UI timer, every 30s
       redraw countdowns only

PanelView
  -> ProviderCard(Claude Code)
  -> ProviderCard(Codex)
  -> Claude task list
  -> launch at login / refresh / quit controls
```

The data model is provider-based:

- `ProviderUsage`: provider name, source, freshness, windows, status, error, hint.
- `UsageWindow`: 5-hour or weekly window, used fraction, reset time, status.
- `ProviderFreshness`: `live`, `stale`, `unavailable`, `missingToken`, or `error`.

## 2. Claude Code Source

Claude support is active and official-header based.

TokenMeter reads the token from:

```text
~/.claude/ccmenubar/claude-token
```

Home resolution checks `$HOME` first, then the system account home and `/Users/<username>`. This avoids missing data on Macs where the account home and shell `HOME` differ.

It sends a tiny Anthropic Messages request:

```http
POST https://api.anthropic.com/v1/messages
Authorization: Bearer sk-ant-oat01-...
anthropic-beta: oauth-2025-04-20
anthropic-version: 2023-06-01
content-type: application/json

{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 1,
  "system": "You are Claude Code, Anthropic's official CLI for Claude.",
  "messages": [{ "role": "user", "content": "." }]
}
```

The response body is ignored. TokenMeter reads these headers:

```text
anthropic-ratelimit-unified-5h-utilization
anthropic-ratelimit-unified-5h-reset
anthropic-ratelimit-unified-5h-status
anthropic-ratelimit-unified-7d-utilization
anthropic-ratelimit-unified-7d-reset
anthropic-ratelimit-unified-7d-status
anthropic-ratelimit-unified-status
```

Claude utilization is a fraction from `0` to `1`. Reset values are epoch seconds.

## 3. Codex Source

Codex support is passive and best effort.

TokenMeter tries these local SQLite databases in order:

```text
~/.codex/logs_2.sqlite
~/.codex/sqlite/logs_2.sqlite
```

The same home-resolution fallback is used for Codex logs.

It queries recent rows from the `logs` table where `feedback_log_body` contains both:

```text
codex.rate_limits
websocket event:
```

Then it extracts and parses the JSON after `websocket event:`.

Typical event shape:

```json
{
  "type": "codex.rate_limits",
  "plan_type": "pro",
  "rate_limits": {
    "allowed": true,
    "limit_reached": false,
    "primary": {
      "used_percent": 1,
      "window_minutes": 300,
      "reset_after_seconds": 17306,
      "reset_at": 1781319647
    },
    "secondary": {
      "used_percent": 59,
      "window_minutes": 10080,
      "reset_after_seconds": 54199,
      "reset_at": 1781356541
    }
  }
}
```

Mapping:

- `primary` -> 5-hour Codex window.
- `secondary` -> weekly Codex window.
- `used_percent` is normalized to a `0...1` fraction for UI rendering.
- `reset_at` is epoch seconds.
- `observedAt` is inferred as `reset_at - reset_after_seconds`.

## 4. Codex Freshness

Codex data is not a live API read. TokenMeter therefore labels freshness:

- **fresh**: latest inferred observation is <= 10 minutes old.
- **stale**: latest snapshot is older than 10 minutes but at least one reset time is still in the future.
- **unavailable**: no parseable event, database unreadable, or all reset windows are already in the past.

When Codex is stale or unavailable, TokenMeter does not probe the model. It asks the user to open Codex, complete one normal request, and refresh.

## 5. Why No Active Codex Probe?

Claude has a low-cost inference-header path that returns official usage. Codex does not currently expose an equivalent public personal quota endpoint for a third-party menu-bar app.

OpenAI's public Codex docs describe plan usage windows and rate-limit concepts, but not a stable local REST endpoint for current personal usage. Current Codex desktop builds receive `codex.rate_limits` over their own websocket stream and may log it locally. TokenMeter reads local logs only, scanning both `~/.codex/logs_2.sqlite` and `~/.codex/sqlite/logs_2.sqlite` and choosing the freshest parseable snapshot.

This keeps TokenMeter honest:

- no hidden Codex request;
- no quota spent just for monitoring;
- no scraping browser sessions or private storage;
- clear stale/unavailable state when the local snapshot is old.

## 6. Build

`build.sh` produces `TokenMeter.app`:

- Bundle ID: `com.tokenmeter.TokenMeter`
- Version: `2.0.2`
- App icon: generated from `assets/app-icon.png`
- Menu-bar agent: `LSUIElement=true`
- Minimum macOS: 14.0
- Linker: `-framework AppKit -lsqlite3`

Debug helpers:

```bash
TOKENMETER_SHOW=1 open TokenMeter.app
./TokenMeter.app/Contents/MacOS/TokenMeter --render assets/screenshot.png
```

---

# TokenMeter 技术说明（中文）

TokenMeter 合并了两个完全不同的额度来源：

- Claude Code 通过 Anthropic 推理响应头暴露官方用量。
- Codex 目前只能从本机 websocket 日志里读到有用的 rate-limit 快照。

App 会把这两种来源分开处理，并明确显示 Codex 数据的新鲜度。

---

## 1. 架构

TokenMeter 是一个单文件原生 macOS App（`main.swift`），使用 AppKit + SwiftUI：

```text
NSStatusItem
  -> 菜单栏紧凑标题：Cl 9% · ~Cx 59%
  -> 点击打开 FloatingPanel

AppDelegate
  -> 数据定时器，每 120 秒
       ClaudeFetcher.fetch()
       CodexFetcher.fetch()
       Fetcher.fetchTasks()
  -> UI 定时器，每 30 秒
       只刷新倒计时，不发网络请求

PanelView
  -> ProviderCard(Claude Code)
  -> ProviderCard(Codex)
  -> Claude 当前任务列表
  -> 开机自启 / 刷新 / 退出
```

数据模型按 provider 拆分：

- `ProviderUsage`：provider 名称、数据来源、新鲜度、窗口、状态、错误、提示。
- `UsageWindow`：5 小时或每周窗口、已用比例、重置时间、状态。
- `ProviderFreshness`：`live`、`stale`、`unavailable`、`missingToken`、`error`。

## 2. Claude Code 数据来源

Claude 支持是主动读取、官方响应头口径。

TokenMeter 从这里读取 token：

```text
~/.claude/ccmenubar/claude-token
```

Home 路径解析会优先使用 `$HOME`，再回退到系统账号 home 和 `/Users/<username>`，避免 macOS 账号 home 与 shell `HOME` 不一致时读错位置。

然后发送一个极小的 Anthropic Messages 请求：

```http
POST https://api.anthropic.com/v1/messages
Authorization: Bearer sk-ant-oat01-...
anthropic-beta: oauth-2025-04-20
anthropic-version: 2023-06-01
content-type: application/json

{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 1,
  "system": "You are Claude Code, Anthropic's official CLI for Claude.",
  "messages": [{ "role": "user", "content": "." }]
}
```

响应正文会被忽略，只读取这些响应头：

```text
anthropic-ratelimit-unified-5h-utilization
anthropic-ratelimit-unified-5h-reset
anthropic-ratelimit-unified-5h-status
anthropic-ratelimit-unified-7d-utilization
anthropic-ratelimit-unified-7d-reset
anthropic-ratelimit-unified-7d-status
anthropic-ratelimit-unified-status
```

Claude 的 utilization 是 `0` 到 `1` 的小数，reset 是 epoch 秒。

## 3. Codex 数据来源

Codex 支持是被动读取、最佳努力。

TokenMeter 按顺序尝试读取：

```text
~/.codex/logs_2.sqlite
~/.codex/sqlite/logs_2.sqlite
```

Codex 日志也使用同一套 home 路径候选。

它查询 `logs` 表中 `feedback_log_body` 同时包含以下内容的最近行：

```text
codex.rate_limits
websocket event:
```

然后解析 `websocket event:` 后面的 JSON。

典型事件结构：

```json
{
  "type": "codex.rate_limits",
  "plan_type": "pro",
  "rate_limits": {
    "allowed": true,
    "limit_reached": false,
    "primary": {
      "used_percent": 1,
      "window_minutes": 300,
      "reset_after_seconds": 17306,
      "reset_at": 1781319647
    },
    "secondary": {
      "used_percent": 59,
      "window_minutes": 10080,
      "reset_after_seconds": 54199,
      "reset_at": 1781356541
    }
  }
}
```

映射关系：

- `primary` -> Codex 5 小时窗口。
- `secondary` -> Codex 每周窗口。
- `used_percent` 会转为 `0...1` 小数，供 UI 渲染。
- `reset_at` 是 epoch 秒。
- `observedAt` 通过 `reset_at - reset_after_seconds` 推断。

## 4. Codex 新鲜度

Codex 数据不是实时 API 读取，所以 TokenMeter 会标记新鲜度：

- **fresh**：最新推断观察时间在 10 分钟内。
- **stale**：快照超过 10 分钟，但至少一个 reset 时间仍在未来。
- **unavailable**：没有可解析事件、数据库不可读，或所有窗口 reset 时间都已经过去。

当 Codex 过期或不可用时，TokenMeter 不会主动探测模型，只提示用户打开 Codex、正常完成一次请求后刷新。

## 5. 为什么不主动探测 Codex？

Claude 有低成本的推理响应头路径，可以返回官方用量。Codex 目前没有给第三方菜单栏 App 使用的公开个人额度 REST 接口。

OpenAI 公开 Codex 文档说明了计划用量窗口和 rate-limit 概念，但没有提供稳定的本地当前用量接口。当前 Codex 桌面版通过自己的 websocket stream 接收 `codex.rate_limits`，并可能写入本机日志。TokenMeter 只读取本机日志，会同时扫描 `~/.codex/logs_2.sqlite` 与 `~/.codex/sqlite/logs_2.sqlite`，并选择最新、可解析的快照。

这样做的边界更清楚：

- 不偷偷发 Codex 请求；
- 不为了监控而消耗额度；
- 不抓浏览器会话或私有存储；
- 本机快照过旧时明确显示 stale/unavailable。

## 6. 构建

`build.sh` 会生成 `TokenMeter.app`：

- Bundle ID：`com.tokenmeter.TokenMeter`
- 版本：`2.0.2`
- App 图标：由 `assets/app-icon.png` 生成
- 菜单栏代理：`LSUIElement=true`
- 最低 macOS：14.0
- 链接参数：`-framework AppKit -lsqlite3`

调试命令：

```bash
TOKENMETER_SHOW=1 open TokenMeter.app
./TokenMeter.app/Contents/MacOS/TokenMeter --render assets/screenshot.png
```
