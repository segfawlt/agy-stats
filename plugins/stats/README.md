# stats (`/stats` Antigravity Plugin)

Companion Antigravity plugin for [`agy-stats`](https://github.com/segfawlt/agy-stats). Automatically installed to `~/.gemini/config/plugins/stats/` by `agy-stats --install` (and removed cleanly by `agy-stats --uninstall`).

## Commands

- `/stats` — Interactive range picker (`5h`, `today`, `7d`, `days`, `all`, `web`) or your pinned default window
- `/stats 5h` / `/stats today` / `/stats 7d` / `/stats 30d` / `/stats all` — Mini Web Overview for that exact window (live quota bars, window KPIs, visual hourly/daily activity chart, active models, and top sessions)
- `/stats days` — 10-day daily token & weekly quota bar chart
- `/stats quota` / `/stats models` / `/stats sessions` — Focused telemetry tables
- `/stats web` — Launch the detached Web Dashboard (`http://localhost:3872`)
- `/stats onboard` — Configure bare `/stats` behavior and displayed sections
