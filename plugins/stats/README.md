# stats (`/stats` Antigravity Plugin)

Companion Antigravity plugin for [`agy-stats`](https://github.com/segfawlt/agy-stats). Automatically installed to `~/.gemini/config/plugins/stats/` and `~/.gemini/config/skills/stats/` by `agy-stats --install` (and removed cleanly by `agy-stats --uninstall`).

## Zero-LLM Instant Slash Commands (0 Model Tokens)

Handled directly in Python via a `PreInvocation` lifecycle hook (`~/.local/bin/agy-stats --pre-invocation-hook`) before the LLM is ever contacted:

- `/stats` — Immediately prints your default window overview (`5h` by default, 0 LLM tokens)
- `/stats 5m` / `/stats 1h` / `/stats 5h` / `/stats 6h` / `/stats 24h` / `/stats today` / `/stats 7d` / `/stats 30d` / `/stats all` — Mini Web Overview for any preset or custom `<N>m`, `<N>h`, `<N>d` window (live quota bars, window KPIs, visual minute/hourly/daily activity chart, active models, and top sessions)
- `/stats days` — 10-day daily token & weekly quota bar chart
- `/stats quota` / `/stats models` / `/stats sessions` — Focused telemetry tables
- `/stats set <range>` — Change your default bare `/stats` view (e.g. `/stats set today`, `/stats set days`, `/stats set 5h`)
- `/stats web` — Launch the detached Web Dashboard (`http://localhost:3872`)

## Interactive Setup & Chat Skill

- `/stats onboard` — Interactive multi-choice wizard (`ask_question`) to customize bare `/stats` and displayed sections
