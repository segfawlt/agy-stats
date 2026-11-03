---
name: stats
description: Inspect live Antigravity quota pools, time-windowed token and request overviews (/stats 5h, /stats today, /stats 7d, /stats days, /stats all), configure /stats preferences (/stats onboard), or launch the interactive Web Dashboard (/stats web). Triggered by /stats or when the user asks to check their token usage, quota runway, or telemetry stats.
---

# Antigravity Telemetry & Quota Slash Skill (`/stats`)

Use this skill whenever the user invokes `/stats` (with or without arguments).

## Command Routing

Always invoke `~/.local/bin/agy-stats` directly via `run_command` (`WaitMsBeforeAsync: 5000`). Do not invoke the shell function `agy stats` inside non-interactive subshells.

### 1. Bare `/stats` (No Arguments)

1. Run `~/.local/bin/agy-stats --slash` via `run_command`.
2. Inspect the stdout:
   - **If stdout contains `[SLASH_PICKER_REQUIRED]`**:
     - Immediately call `ask_question` so the user can pick their time window with a single click:
       - `question`: `"Select a time window or view for /stats:"`
       - `is_multi_select`: `false`
       - `options`:
         - `"(Recommended) 5h — Active 5-hour quota window overview"`
         - `"today — Since midnight local time"`
         - `"7d — Last 7 days overview & daily chart"`
         - `"days — 10-day daily token & quota ledger chart"`
         - `"all — All-time telemetry overview"`
         - `"web — Open interactive Web Dashboard (localhost:3872)"`
     - Map the chosen option to its leading token (`5h`, `today`, `7d`, `days`, `all`, or `web`), run `~/.local/bin/agy-stats --slash <token>`, and display the resulting report inside a fenced `text` code block.
   - **If stdout does NOT contain `[SLASH_PICKER_REQUIRED]`** (the user configured a default range or launched web):
     - Display the stdout directly inside a fenced `text` code block.

### 2. Time-Window Overview or Subview (`/stats <arg>`)

Supported arguments:
- **Time ranges**: `1h`, `5h`, `today`, `24h`, `7d`, `days` (`10d`), `30d`, `all`, or any `<N>h` / `<N>d` (e.g. `2h`, `14d`)
- **Focused views**: `quota`, `models`, `sessions`

Execution:
1. Run `~/.local/bin/agy-stats --slash <arg>` via `run_command`.
2. Present the exact stdout inside a single fenced `text` code block (` ```text ... ``` `) so box-drawing borders and Unicode bar charts stay aligned in monospace.
3. Keep commentary minimal (1 short line noting `/stats web` opens the full interactive dashboard or `/stats onboard` customizes the default view). Do not repeat every metric in prose.

### 3. Launch Web Dashboard (`/stats web`)

1. Run `~/.local/bin/agy-stats --slash web` via `run_command`.
2. This starts the background server on `http://localhost:3872` (if not already running), opens the browser, and exits immediately. Confirm the URL to the user.

### 4. Interactive Onboarding (`/stats onboard` or `/stats settings`)

1. Call `ask_question` with two questions in a single turn:
   - **Question 1** (`is_multi_select: false`): `"What should bare /stats do when invoked without arguments?"`
     - `"(Recommended) ask — Prompt for a time window (5h, today, 7d, days, all, web)"`
     - `"5h — Immediately show 5-hour window overview"`
     - `"today — Immediately show today's overview"`
     - `"7d — Immediately show 7-day overview"`
     - `"days — Immediately show 10-day daily bar chart"`
     - `"web — Immediately launch Web Dashboard"`
   - **Question 2** (`is_multi_select: true`): `"Which sections should appear in /stats <range> reports?"`
     - `"(Recommended) quota — Live 5h & Weekly quota progress bars"`
     - `"(Recommended) kpis — Window KPIs (requests, tokens, cache hit %, output, speed, latency)"`
     - `"(Recommended) chart — Visual activity bar chart (hourly or daily)"`
     - `"(Recommended) models — Active model breakdown in window"`
     - `"(Recommended) sessions — Top sessions in window"`
     - `"reset — Server vs. Local since-reset quota breakdown"`
     - `"pacing — 6-day target & active burn pacing"`
2. Extract the selected keys (e.g. `slash_range=5h` and `slash_sections=quota,kpis,chart,models,sessions`) and persist them via:
   ```bash
   ~/.local/bin/agy-stats --settings slash_range=<mode> slash_sections=<comma_separated_keys>
   ```
3. Run `~/.local/bin/agy-stats --slash <preview_range>` (using their chosen default range, or `5h` if they chose `ask`) and show the preview inside a fenced `text` code block.
