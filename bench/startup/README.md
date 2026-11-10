# New-tab startup benchmark (GTK)

Measures new-tab latency using the `startup` log lines from
`src/StartupTrace.zig`.

```sh
zig build -Doptimize=ReleaseFast -p /tmp/gb/base
bench/startup/bench.sh /tmp/gb/base/bin/ghostty base 20 fake
bench/startup/bench.sh /tmp/gb/base/bin/ghostty base 20 shell
bench/startup/bench.sh /tmp/gb/base/bin/ghostty nocg 20 fake "linux-cgroup = never"
python3 bench/startup/parse.py base /tmp/ghostty-bench/run-*/log   # pool runs
```

- Starts an isolated instance (`--class=com.example.ghosttybench.<label>`,
  no default config files), opens N tabs with `ghostty +new-tab`, then
  kills it. Windows appear on your desktop while it runs.
- `fake` uses a shell that only prints OSC 133;A, which isolates
  Ghostty's own cost. `shell` uses your login shell with shell integration.
- Extra arguments are appended as config lines.
- Logs go to `/tmp/ghostty-bench/run-<label>-<mode>/`.

Results on 1.4.0 (median of 3x20 warm tabs, fake shell):

| ms                         | 1.4.0 | + cgroup | + shader cache |
|----------------------------|------:|---------:|---------------:|
| subprocess_started         |  34.8 |      9.5 |            8.8 |
| shaders_compiled           |  15.3 |     15.3 |            7.6 |
| new tab -> first frame     |  41.5 |     44.0 |           34.2 |
| new tab -> first prompt    |  52.2 |     25.6 |           22.7 |
