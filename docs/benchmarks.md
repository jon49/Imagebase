# Before / after: TrailBase + WASM guest vs. the Goose server

**Before** is the last TrailBase commit (`e444c51`): `trail` v0.35.4 with the Rust
`wasm32-wasip2` guest. **After** is `server/imagebase`, built with Goose v2026.4
(gcc 13.3, `-O3`). Both ran on the same 12-thread Linux x86-64 machine,
one after the other, with the same data and the same load script.

Reproduce with `bench/run-trailbase.sh` and `bench/run-imagebase.sh`, each with
`--duration 15 --concurrency 8` and then `--duration 10 --concurrency 1`. Render a
table with `bench/compare.py before.json after.json`. The raw numbers are the
`bench/results-*.json` files.

## Method

The two runners do the same setup. Each starts the server on a fresh data dir,
registers, verifies and logs in 12 users in three groups of 4, one group per
data set. Each user in the read group gets 200 keys written twice (400 rows),
and one 4 KB page is published. `bench.py` then drives 5 scenarios over
HTTP/1.1 keep-alive connections. While a scenario runs, it samples the server
process from `/proc`: CPU time (utime+stime) and RSS every 50 ms.

| scenario | request |
|---|---|
| page GET (public) | `GET /api/pages/bench/{id}`, 4 KB of HTML |
| sync write 10 rows | `POST /api/data/bench` by the write group, from a caught-up client: 10 inserts, `saved` echoed |
| sync read 200 rows | `POST /api/data/bench` by the read group, cursor 0: the window query over 400 rows, 200 returned |
| sync empty (auth only) | `POST /api/data/bench` by the empty group: JWT check, user lookup, membership query, empty pull |
| login (password hash) | `POST /api/auth/v1/login`: Argon2id with m=19456 KiB, t=2, p=1 on both |

Against TrailBase the paths carry an app id (`bench`, `--app-paths`), as it
requires; the current server serves one app and takes `/api/data` and
`/api/pages/{id}`.

The numbers below were measured before the server dropped its `app`
namespace. Back then the runners kept the data sets apart with three app ids
on 4 users instead of three groups of users, which is the same work per
request. A 1-second check of each scenario with the current runners and
server gave the same or lower CPU per request (for example sync read at 8
clients: 957 µs against 1,544 µs). It was too short to replace these numbers.

The load generator is Python, running on the same machine, so absolute
throughput is partly bounded by the client and by CPU contention. The most
comparable number is **server CPU per request**, and the cleanest run for it is
concurrency 1, where nothing is saturated.

## Memory

| | TrailBase | Goose | |
|---|---:|---:|---|
| RSS at startup, empty data dir | 99.7 MB | **7.1 MB** | 14x less |
| RSS after setup (8 logins, 1,600 rows, 1 page) | 104.5 MB | **10.6 MB** | 9.8x less |
| RSS during sync/page load, 8 clients | 122–156 MB | **10.8–16.1 MB** | ~10x less |
| peak RSS (8 concurrent Argon2 logins) | 340 MB | **168 MB** | 2.0x less |
| RSS at the end of the run | 320 MB | **16 MB** | 20x less |
| binary on disk | 83.7 MB `trail` + 0.66 MB wasm | **0.32 MB** + system libsqlite3 | |
| cold start to first response | 161 ms | **64 ms** | |

The peak is Argon2's 19 MiB working buffer per concurrent login, in both
servers. The Goose build maps it per hash and unmaps it straight after, so RSS
falls back to about 16 MB. TrailBase keeps about 320 MB resident after a burst
of logins.

## CPU per request, concurrency 1

| scenario | TrailBase | Goose | |
|---|---:|---:|---|
| page GET (public) | 2,446 µs | **35 µs** | 69x less |
| sync write 10 rows | 1,906 µs | **300 µs** | 6.3x less |
| sync read 200 rows | 9,167 µs | **831 µs** | 11x less |
| sync empty (auth only) | 1,170 µs | **68 µs** | 17x less |
| login (Argon2id) | 17.8 ms | 17.8 ms | same |

## Throughput and latency, 8 concurrent clients

| scenario | TrailBase req/s | Goose req/s | TrailBase p50 / p99 | Goose p50 / p99 | CPU µs/req (T → G) |
|---|---:|---:|---:|---:|---:|
| page GET (public) | 186 | **50,378** | 43.1 / 44.8 ms | 0.15 / 0.37 ms | 1,807 → 32 |
| sync write 10 rows | 942 | **3,274** | 2.6 / 76.0 ms | 1.7 / 15.1 ms | 1,838 → 324 |
| sync read 200 rows | 165 | **3,832** | 48.0 / 59.8 ms | 1.9 / 6.8 ms | 5,676 → 1,544 |
| sync empty (auth only) | 2,916 | **22,052** | 1.1 / 24.3 ms | 0.31 / 1.3 ms | 914 → 100 |
| login (Argon2id) | 107 | **119** | 77.9 / 142 ms | 67.2 / 148 ms | 71,760 → 60,807 |

## Reading the numbers

- **TrailBase's ~43 ms floor** on the page and 200-row responses is a TCP stall
  between Nagle's algorithm and delayed ACKs. The response leaves in more than
  one write, and the second write waits for an ACK that the client delays by
  about 40 ms. This, not CPU, caps those scenarios at 186 and 165 req/s, so
  their req/s ratios overstate the CPU difference. Browsers and other HTTP
  clients see the same stall. The Goose front end sets `TCP_NODELAY` and writes
  each response once.
- **Sync read at 8 clients** costs 1,544 µs against 831 µs serially. The Goose
  server kept 6 of the 12 hardware threads busy, sharing them with the Python
  client processes, so hyper-threads ran at reduced speed. TrailBase never got
  past one core in that scenario, because of the stall above.
- **Writes are serialized** by a process-wide write gate: SQLite allows only one
  writer at a time. At 8 clients the gate holds p99 to 15 ms, against 76 ms for
  TrailBase. Without the gate, SQLite's sleep-and-retry busy handler had put
  p99 at 835 ms.
- **Login is Argon2-bound** in both. The vendored reference implementation picks
  an AVX2 block-fill at runtime when the CPU supports it, which brings it level
  with TrailBase's Rust implementation. With SSE2 only it was about 40% slower.

## Two fixes the measurements found

1. SQLite's memory statistics (`SQLITE_CONFIG_MEMSTATUS`, on by default) take a
   global mutex on every allocation. With one connection per worker, that was
   the bottleneck for concurrent reads. Turning it off took "sync read" at 8
   clients from 4,749 to about 1,500 µs per request.
2. Argon2 buffers are allocated with mmap and freed with munmap, so they are
   returned to the OS. With malloc, each worker thread's arena kept about
   19 MB after its first login, which put RSS after setup at 142 MB instead of
   11 MB.
