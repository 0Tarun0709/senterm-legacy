# senterm performance baseline

rerun with `python3 scripts/benchmark.py`. three sequential release trials per app, on the same mac, at 113×44. the libghostty preview uses its standalone appkit renderer, so its startup and memory do not represent the full senterm app.

| metric | senterm / swiftterm | libghostty preview | ghostty 1.3.0 |
|---|---:|---:|---:|
| launch to pty ready | 881 ms | 719 ms | 932 ms |
| idle app rss | 91.0 mib | 50.5 mib | 109.9 mib |
| app cpu during mixed visual workload | 7.0% | 23.3% | 2.5% |
| visible update at 8 hz, idle, median / p95 | 32.5 / 39.6 ms | 10.4 / 18.5 ms | 17.0 / 25.6 ms |
| visible update at 8 hz, scrolling logs, median / p95 | 36.0 / 42.1 ms | 34.8 / 42.3 ms | 17.1 / 26.7 ms |
| captured updates at 30 hz with logs | 177/180 | 176/180 | 179/180 |
| pty reply after 10,000 colored lines | 21.9 ms | 17.0 ms | 9.8 ms |
| pty reply after 10,000 plain lines | 14.6 ms | 14.5 ms | 7.9 ms |
| pty reply after 10,000 unicode lines | 57.1 ms | 11.5 ms | 5.5 ms |
| pty reply after 10,000 escape-heavy updates | 34.3 ms | 12.5 ms | 8.4 ms |

visible timings include macos capture delivery. each app matched 45 of 48 updates in each 8 hz workload. missing capture updates do not imply lost terminal output.

## senterm split probe

- local key event to parsed shell echo: **16.5 ms median, 32.2 ms p95** idle; **16.6 ms median, 39.7 ms p95** while a sibling pane emits logs (16 samples each).
- programmatic scroll jump to viewport state: **0.02 ms median, 0.24 ms p95**; tab switch to focus: **29.3 ms** during logs. neither is a paint measurement.
- one live shell: **108.5 mib rss, 0.22% app cpu**; six projects with six live idle shells: **128.2 mib, 3.37% app cpu**. cpu is from a single two-second sample per configuration.
- vim displayed and saved the expected text, tmux started and exited a disposable session, and vttest displayed its menu and exited. the split probe also checked scroll position and sibling survival after exit.

the raw trials and split log were saved to a temporary directory on the benchmark mac, not in this repository. the runner prints the output path for each new run.

no global keys were injected. physical key-to-display and wheel-to-display latency, regression budgets, full vttest conformance, and cross-app comparisons of the split probe were not measured.
