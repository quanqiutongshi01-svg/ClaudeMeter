# ClaudeMeter — Technical Notes

How ClaudeMeter gets the **official** Claude usage numbers, how the app is put together, and what was ruled out along the way.

---

## 1. The core problem: where do the official numbers live?

The Claude desktop app's *Settings → Usage* shows a 5-hour "Current session" gauge and a weekly "All models" gauge. We want the same numbers in a menu bar.

Things that **don't** work:

| Approach | Why it fails |
|---|---|
| Parse `~/.claude/projects/**/*.jsonl` and sum tokens (e.g. via `ccusage`) | This is an **estimate**. It sums raw tokens (incl. cache reads) and divides by a *guessed* limit. The official % is **server-side weighted** (cache reads are cheaper, models weighted, real plan ceiling), so it diverges badly — e.g. estimate said 8 % while the official 5h gauge said 48 %. |
| `GET https://api.anthropic.com/api/oauth/usage` | This is the endpoint the CLI's `/usage` uses, and it returns exact per-window utilization. **But it requires the `user:profile` OAuth scope.** A token from `claude setup-token` lacks it → `403 permission_error: OAuth token does not meet scope requirement user:profile`. The scope *does* exist on the interactive login token, but that lives in the desktop app's managed session (not in a standard file/keychain) and rotates — not reliable to read. |
| Scrape the desktop app's `claude.ai` IndexedDB / HTTP cache | The fetched usage is held transiently, structured-clone encoded, and blobs rotate. Fragile. |

## 2. The solution: rate-limit response headers

Every **inference** response from `api.anthropic.com` carries unified rate-limit headers describing the subscription's 5-hour and weekly windows. A `claude setup-token` token has the inference scope, so it **can** make this call — and the headers give us exactly what we need, no `user:profile` required.

ClaudeMeter sends the smallest possible request (`max_tokens: 1`) and ignores the body — only the headers matter.

### The request

```http
POST https://api.anthropic.com/v1/messages
Authorization: Bearer sk-ant-oat01-…        # from `claude setup-token`
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

Two non-obvious requirements:

1. **`anthropic-beta: oauth-2025-04-20`** — without the oauth beta flag the token isn't accepted.
2. **The `system` prompt must start with `You are Claude Code, Anthropic's official CLI for Claude.`** — subscription OAuth tokens are authorized only for Claude Code-style traffic; a request that doesn't look like Claude Code is rejected. This prefix satisfies that check. (We use the cheapest model and 1 output token to keep it trivial.)

### The response headers we read

```
anthropic-ratelimit-unified-status:            allowed        # overall: allowed | allowed_warning | rejected
anthropic-ratelimit-unified-5h-utilization:    0.09           # 5-hour window, fraction used (0–1)
anthropic-ratelimit-unified-5h-reset:          1781328600     # unix epoch seconds
anthropic-ratelimit-unified-5h-status:         allowed
anthropic-ratelimit-unified-7d-utilization:    0.23           # weekly window, fraction used
anthropic-ratelimit-unified-7d-reset:          1781805600
anthropic-ratelimit-unified-7d-status:         allowed
anthropic-ratelimit-unified-representative-claim: five_hour
```

- `5h` → *Settings → Usage* "Current session". `7d` → "Weekly / All models".
- `utilization` is a fraction; multiply by 100 for the percent the UI shows. Remaining = `1 − utilization`.
- `reset` is absolute epoch seconds — used for both the live countdown and the absolute clock ("today 13:30", "周五 02:00"). Using the absolute value means the countdown never drifts.

These match *Settings → Usage* to the percent (modulo the few seconds between reads). The weekly `reset` even lands on the exact "Resets Fri 2:00 AM" the UI shows.

## 3. App architecture

Single Swift file (`main.swift`), AppKit + SwiftUI, no external dependencies.

```
NSStatusItem (menu bar)  ── click ──▶  FloatingPanel (NSPanel)
        │                                   │
        │  title: 🟢 5h 9%·4h32m · 周 23%·5d17h
        │                                   └─ NSHostingView(PanelView)  ← SwiftUI, dark HUD glass
        ▼
   AppDelegate
     ├─ dataTimer (120 s) ─▶ Fetcher.fetchAll() on a background queue
     │                          ├─ loadToken()        ~/.claude/ccmenubar/claude-token
     │                          ├─ fetchOfficial()    POST /v1/messages, read headers (URLSession + semaphore)
     │                          └─ fetchTasks()        newest ~/.claude/tasks/<session>/*.json
     └─ uiTimer  (30 s)  ─▶ bump a tick + redraw countdowns (no network)
```

- **Polling:** the 120 s data timer does the network read; the 30 s UI timer only re-renders the countdown from the stored `reset` Date, so the menu bar ticks down smoothly without extra requests.
- **Panel:** `NSPanel` with `.borderless + .nonactivatingPanel`, `level = .floating`, `isMovableByWindowBackground = true`, an `NSVisualEffectView(.hudWindow)` background, dark appearance. `canBecomeKey` is overridden so the in-panel buttons receive clicks.
- **Menu bar agent:** `NSApp.setActivationPolicy(.accessory)` + `LSUIElement` → no Dock icon.
- **Launch at login:** `SMAppService.mainApp.register()`.
- **`--render <path.png>`:** an offline mode that rasterizes the panel (with live data) to a PNG via SwiftUI `ImageRenderer` — handy for docs/screenshots and for verifying the UI without screen-recording permission. `CCMETER_SHOW=1` auto-opens the panel on launch (debug).

## 4. Token: storage, scope, security

- Minted by `claude setup-token` (requires a Claude subscription); valid ~1 year.
- Stored in plain text at `~/.claude/ccmenubar/claude-token`; the app trims whitespace on read. `chmod 600` recommended.
- Scope is inference-only — enough for the header trick, **not** enough for `/api/oauth/usage`.
- The app reads the token only to set the `Authorization` header; it is never logged, printed, or sent anywhere except `api.anthropic.com`.
- The home directory is resolved via `FileManager.homeDirectoryForCurrentUser`, so relocated/`CLAUDE_CONFIG_DIR`-style setups that move `~` still resolve to the right `.claude`.

## 5. Why Codex isn't supported (investigation summary)

The Codex desktop app (OpenAI) was investigated as a second provider. Findings:

- Its official rate-limit snapshot (`codex.rate_limits` → `primary` = 5h / `secondary` = weekly, with `used_percent` + `reset_at`) is only **incidentally** logged to `~/.codex/logs_2.sqlite` (`logs.feedback_log_body`).
- On a real machine that table was **pruned to zero live rows**; current Codex builds keep the live value in the renderer/websocket and **don't persist a fresh, pollable copy**.
- There is **no REST usage endpoint** — rate limits arrive embedded in the `responses_websocket` stream, so a passive monitor can't poll them without making a real model turn.

Net: a background menu-bar reader can't reliably obtain current Codex usage today. If a future Codex build persists the snapshot, the same header/snapshot pattern used here would slot in.

## 6. Build

`build.sh` compiles `main.swift` with `swiftc -O` into a `.app` bundle:

- Writes `Info.plist` with `LSUIElement=true` (menu-bar agent) and `LSMinimumSystemVersion=14.0`.
- `-target arm64-apple-macos14.0` (change to `x86_64-…` for Intel).
- Ad-hoc code signs (`codesign --sign -`). Not notarized — a downloaded build needs a right-click → Open, or quarantine removal. Building locally avoids the prompt.
- SwiftUI's two-parameter `onChange` and `SMAppService` require the macOS 14 target.
