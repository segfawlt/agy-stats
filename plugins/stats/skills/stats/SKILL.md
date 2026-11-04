---
name: stats
description: Inspect live Antigravity quota pools, time-windowed token and request overviews (/stats, /stats 5m, /stats 1h, /stats 5h, /stats 24h, /stats today, /stats 7d, /stats days, /stats all), configure /stats preferences (/stats onboard), or launch the interactive Web Dashboard (/stats web). Triggered by /stats or when the user asks to check their token usage, quota runway, or telemetry stats.
---

# Antigravity Telemetry & Quota Slash Skill (`/stats`)

Direct `/stats` commands (`/stats`, `/stats 5m`, `/stats 1h`, `/stats 5h`, `/stats 24h`, `/stats today`, `/stats 7d`, `/stats days`, `/stats all`, `/stats web`, `/stats web stop`, `/stats set <range>`) are intercepted automatically in Python before the LLM is called (zero model tokens, ~50ms).

This skill is used in two cases:
1. When the user runs `/stats onboard` (or `/stats setup` / `/stats settings`) to interactively configure their preferences using `ask_question`.
2. When the user asks a natural-language question about their token usage, quota runway, models, or sessions in chat.

## Command Routing

Always invoke `~/.gemini/config/plugins/stats/bin/agy-stats` directly via `run_command` (`WaitMsBeforeAsync: 5000`). Do not invoke the shell function `agy stats` inside non-interactive subshells.

### 1. Interactive Onboarding (`/stats onboard` or `/stats settings`)

1. Call `ask_question` with two questions in a single turn:
   - **Question 1** (`is_multi_select: false`): `"What should bare /stats print by default (instant, 0 LLM tokens)?"`
     - `"(Recommended) 5h — Active 5-hour quota window overview"`
     - `"today — Since midnight local time"`
     - `"24h — Last 24 hours overview & hourly chart"`
     - `"7d — Last 7 days overview & daily chart"`
     - `"days — 10-day daily token & quota ledger chart"`
     - `"all — All-time telemetry overview"`
     - `"web — Immediately launch Web Dashboard (localhost:3872)"`
   - **Question 2** (`is_multi_select: true`): `"Which sections should appear in /stats reports?"`
     - `"(Recommended) quota — Live 5h & Weekly quota progress bars"`
     - `"(Recommended) kpis — Window KPIs (requests, tokens, cache hit %, output, speed, latency)"`
     - `"(Recommended) chart — Visual activity bar chart (minute, hourly, or daily)"`
     - `"(Recommended) models — Active model breakdown in window"`
     - `"(Recommended) sessions — Top sessions in window"`
     - `"reset — Server vs. Local since-reset quota breakdown"`
     - `"pacing — 6-day target & active burn pacing"`
2. Extract the selected keys (e.g. `slash_range=5h` and `slash_sections=quota,kpis,chart,models,sessions`) and persist them via:
   ```bash
   ~/.gemini/config/plugins/stats/bin/agy-stats --settings slash_range=<mode> slash_sections=<comma_separated_keys>
   ```
3. Run `~/.gemini/config/plugins/stats/bin/agy-stats --slash <chosen_range>` and show the preview inside a fenced `text` code block.

### 2. Natural-Language Telemetry Questions in Chat

Supported arguments for `~/.gemini/config/plugins/stats/bin/agy-stats --slash <arg>`:
- **Time ranges**: `5m`, `15m`, `30m`, `1h`, `5h`, `6h`, `today`, `24h`, `7d`, `days` (`10d`), `30d`, `all`, or any `<N>m` / `<N>h` / `<N>d`
- **Focused views**: `quota`, `models`, `sessions`, `web`, `web stop`, `set <range>`

Run `~/.gemini/config/plugins/stats/bin/agy-stats --slash <arg>` via `run_command` and present the stdout inside a fenced `text` code block (` ```text ... ``` `).
