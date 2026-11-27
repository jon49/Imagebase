#!/usr/bin/env python3
"""Server-agnostic load + resource benchmark for ImageBase.

Drives a running server over HTTP and samples the server process's CPU time and
memory from /proc while each scenario runs, so the same script measures the
TrailBase build and any rewrite as long as the wire API matches.

    bench.py --url http://localhost:4000 --pid <server pid> \
             --read-tokens a,b --write-tokens c,d --empty-tokens e,f \
             --page-id <uuid> [--duration 10] [--concurrency 8]

Each scenario uses its own users, so their data sets don't mix. Requests go
to /api/data/bench and /api/pages/bench/{id}: the TrailBase server needs the
app segment, and the current server accepts it and ignores it.

Results are printed as a table and written as JSON to --out.
"""

import argparse
import http.client
import json
import multiprocessing as mp
import os
import threading
import time
import urllib.parse

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


# --- /proc sampling ---------------------------------------------------------

def proc_cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    # fields[11], [12] are utime, stime (14th/15th overall, after pid and comm).
    return (int(fields[11]) + int(fields[12])) / CLK_TCK


def proc_mem_kb(pid):
    out = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("VmRSS", "VmHWM", "Threads"):
                out[k] = int(v.split()[0])
    return out


class Sampler(threading.Thread):
    def __init__(self, pid, interval=0.05):
        super().__init__(daemon=True)
        self.pid, self.interval = pid, interval
        self.peak_rss = 0
        self.rss = []
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            m = proc_mem_kb(self.pid)
            self.rss.append(m["VmRSS"])
            self.peak_rss = max(self.peak_rss, m["VmRSS"])
            time.sleep(self.interval)


# --- load workers -----------------------------------------------------------

def worker(url, requests, deadline, out_q, wid):
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    lat, statuses, i = [], {}, wid
    while time.time() < deadline:
        method, path, headers, body = requests[i % len(requests)]
        i += 1
        t0 = time.perf_counter()
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            r.read()
            st = r.status
        except Exception:
            st = "err"
            conn.close()
            conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
        lat.append(time.perf_counter() - t0)
        statuses[st] = statuses.get(st, 0) + 1
    conn.close()
    out_q.put((lat, statuses))


def run_scenario(name, url, pid, requests, duration, concurrency):
    cpu0 = proc_cpu_seconds(pid)
    sampler = Sampler(pid)
    sampler.start()
    t0 = time.time()
    deadline = t0 + duration
    q = mp.Queue()
    procs = [mp.Process(target=worker, args=(url, requests, deadline, q, w))
             for w in range(concurrency)]
    for p in procs:
        p.start()
    results = [q.get() for _ in procs]
    for p in procs:
        p.join()
    wall = time.time() - t0
    sampler.stop.set()
    sampler.join()
    cpu = proc_cpu_seconds(pid) - cpu0

    lat = sorted(x for r in results for x in r[0])
    statuses = {}
    for _, s in results:
        for k, v in s.items():
            statuses[str(k)] = statuses.get(str(k), 0) + v
    n = len(lat)
    pct = lambda p: lat[min(n - 1, int(p * n))] * 1000 if n else 0
    return {
        "scenario": name,
        "requests": n,
        "rps": n / wall,
        "p50_ms": pct(0.50),
        "p99_ms": pct(0.99),
        "statuses": statuses,
        "server_cpu_s": cpu,
        "server_cores_used": cpu / wall,
        "server_cpu_us_per_req": cpu / n * 1e6 if n else 0,
        "peak_rss_mb": sampler.peak_rss / 1024,
        "end_rss_mb": sampler.rss[-1] / 1024 if sampler.rss else 0,
    }


# --- scenarios --------------------------------------------------------------

def sync_body(i, nkeys):
    # A caught-up client pushing changes: the cursor is past every id, so the
    # pull finds nothing and the cost is the 10 inserts plus the response.
    return json.dumps({
        "lastSyncedId": 2**53,
        "data": [{"key": f"k{i}-{j}", "data": {"n": i, "j": j, "s": "x" * 64}}
                 for j in range(nkeys)],
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--read-tokens", required=True, help="tokens of the users seed.py filled")
    ap.add_argument("--write-tokens", required=True, help="tokens of users for the write scenario")
    ap.add_argument("--empty-tokens", required=True, help="tokens of users with no data")
    ap.add_argument("--login", default="", help="email:password for the login scenario")
    ap.add_argument("--page-id", default="")
    ap.add_argument("--duration", type=float, default=10)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--label", default="server")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    read_tokens, write_tokens, empty_tokens = (
        a.read_tokens.split(","), a.write_tokens.split(","), a.empty_tokens.split(","))
    auth = lambda t: {"Authorization": f"Bearer {t}", "Content-Type": "application/json"}

    idle = proc_mem_kb(a.pid)
    report = {"label": a.label, "idle_rss_mb": idle["VmRSS"] / 1024,
              "threads": idle["Threads"], "scenarios": []}

    scenarios = []
    if a.page_id:
        scenarios.append(("page GET (public)",
                          [("GET", f"/api/pages/bench/{a.page_id}", {}, None)]))
    # Writes: each request inserts 10 rows and returns them as `saved`.
    scenarios.append(("sync write 10 rows", [
        ("POST", "/api/data/bench", auth(write_tokens[i % len(write_tokens)]), sync_body(i, 10))
        for i in range(256)]))
    # Reads: no new rows, cursor 0 => returns every latest row of the app (populated
    # in setup) — exercises the ROW_NUMBER() window query and JSON encoding.
    scenarios.append(("sync read 200 rows", [
        ("POST", "/api/data/bench", auth(t), json.dumps({"lastSyncedId": 0}))
        for t in read_tokens]))
    scenarios.append(("sync empty (auth only)", [
        ("POST", "/api/data/bench", auth(t), json.dumps({"lastSyncedId": 0}))
        for t in empty_tokens]))
    if a.login:
        email, pw = a.login.split(":", 1)
        scenarios.append(("login (password hash)", [
            ("POST", "/api/auth/v1/login", {"Content-Type": "application/json"},
             json.dumps({"email": email, "password": pw}))]))

    for name, reqs in scenarios:
        r = run_scenario(name, a.url, a.pid, reqs, a.duration, a.concurrency)
        report["scenarios"].append(r)
        time.sleep(1)

    report["final_rss_mb"] = proc_mem_kb(a.pid)["VmRSS"] / 1024
    report["peak_rss_mb"] = proc_mem_kb(a.pid)["VmHWM"] / 1024

    print(f"\n== {a.label} ==  idle RSS {report['idle_rss_mb']:.1f} MB, "
          f"threads {report['threads']}, peak RSS (VmHWM) {report['peak_rss_mb']:.1f} MB")
    hdr = f"{'scenario':28} {'req/s':>8} {'p50 ms':>8} {'p99 ms':>8} {'cores':>6} {'cpu µs/req':>11} {'peak MB':>8}  statuses"
    print(hdr)
    for r in report["scenarios"]:
        print(f"{r['scenario']:28} {r['rps']:8.0f} {r['p50_ms']:8.2f} {r['p99_ms']:8.2f} "
              f"{r['server_cores_used']:6.2f} {r['server_cpu_us_per_req']:11.0f} "
              f"{r['peak_rss_mb']:8.1f}  {r['statuses']}")
    if a.out:
        with open(a.out, "w") as f:
            json.dump(report, f, indent=2)


if __name__ == "__main__":
    main()
