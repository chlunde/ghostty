"""Summarize StartupTrace logs: parse.py <label> <log>...

Each log is one Ghostty instance; its first surface (cold start) is
reported separately and the remaining tabs are pooled across logs.
"""
import re, sys, statistics as st

EVENTS = ["gtk_widget_to_core_init", "font_grid", "renderer_init",
          "threads_spawned", "subprocess_started", "render_thread_enter",
          "shaders_compiled", "first_frame", "first_prompt"]

def load(path):
    surfaces, cur = [], None
    for line in open(path, errors="replace"):
        m = re.search(r"\(startup\): (\w+) t=(-?\d+)us", line)
        if not m:
            continue
        ev, us = m.group(1), int(m.group(2))
        if ev == "gtk_widget_to_core_init":
            cur = {ev: us}
            surfaces.append(cur)
        elif cur is not None and ev not in cur:
            cur[ev] = us
    return surfaces

def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * p))]

label, paths = sys.argv[1], sys.argv[2:]
runs = [load(p) for p in paths]
cold = [r[0] for r in runs if r]
warm = [s for r in runs for s in r[1:]]
print(f"== {label}: {len(runs)} run(s), {len(warm)} warm tabs; ms")
print(f"{'event':26} {'cold':>7} {'median':>7} {'p90':>7}  (relative to Surface.init)")
for e in EVENTS:
    vals = [s[e] for s in warm if e in s]
    c = [s[e] for s in cold if e in s]
    cs = f"{st.median(c)/1000:7.2f}" if c else "      -"
    if vals:
        print(f"{e:26} {cs} {st.median(vals)/1000:7.2f} {pct(vals, .9)/1000:7.2f}")
for e in ["first_frame", "first_prompt"]:
    tot = [s["gtk_widget_to_core_init"] + s[e] for s in warm if e in s]
    if tot:
        print(f"TOTAL new tab -> {e:13} median={st.median(tot)/1000:6.2f} p90={pct(tot, .9)/1000:6.2f}")
