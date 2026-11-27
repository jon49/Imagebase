#!/usr/bin/env python3
"""Side-by-side table of two bench.py result files: compare.py before.json after.json"""
import json, sys

a, b = (json.load(open(p)) for p in sys.argv[1:3])
def ratio(x, y, lower_better):
    if not x or not y: return ""
    r = x / y if lower_better else y / x
    return f"{r:.1f}x better" if r >= 1 else f"{1/r:.1f}x worse"

print(f"| | {a['label']} | {b['label']} | |")
print("|---|---:|---:|---|")
for k, name in (("idle_rss_mb", "RSS after setup (MB)"), ("peak_rss_mb", "peak RSS, VmHWM (MB)"),
                ("final_rss_mb", "RSS at end (MB)")):
    print(f"| {name} | {a[k]:.1f} | {b[k]:.1f} | {ratio(a[k], b[k], True)} |")
print(f"| threads | {a['threads']} | {b['threads']} | |")
for sa in a["scenarios"]:
    sb = next(s for s in b["scenarios"] if s["scenario"] == sa["scenario"])
    n = sa["scenario"]
    print(f"| **{n}** req/s | {sa['rps']:.0f} | {sb['rps']:.0f} | {ratio(sa['rps'], sb['rps'], False)} |")
    print(f"| {n}: p50 / p99 ms | {sa['p50_ms']:.2f} / {sa['p99_ms']:.2f} | {sb['p50_ms']:.2f} / {sb['p99_ms']:.2f} | {ratio(sa['p50_ms'], sb['p50_ms'], True)} (p50) |")
    print(f"| {n}: server CPU µs/req | {sa['server_cpu_us_per_req']:.0f} | {sb['server_cpu_us_per_req']:.0f} | {ratio(sa['server_cpu_us_per_req'], sb['server_cpu_us_per_req'], True)} |")
    print(f"| {n}: cores busy | {sa['server_cores_used']:.2f} | {sb['server_cores_used']:.2f} | |")
    print(f"| {n}: peak RSS MB | {sa['peak_rss_mb']:.1f} | {sb['peak_rss_mb']:.1f} | {ratio(sa['peak_rss_mb'], sb['peak_rss_mb'], True)} |")
