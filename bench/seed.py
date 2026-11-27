#!/usr/bin/env python3
"""Seed each given user with 200 latest rows (plus 200 overwritten ones).
seed.py URL TOKENS [SYNC_PATH], SYNC_PATH defaulting to /api/data."""
import json, sys, urllib.request
url, tokens = sys.argv[1], sys.argv[2].split(",")
path = sys.argv[3] if len(sys.argv) > 3 else "/api/data"
for t in tokens:
    for rnd in range(2):  # second round overwrites every key, so the window query has dups to skip
        for b in range(4):
            body = {"lastSyncedId": 0, "data": [
                {"key": f"row-{b*50+j}", "data": {"round": rnd, "v": "y" * 100}} for j in range(50)]}
            req = urllib.request.Request(f"{url}{path}", data=json.dumps(body).encode(),
                headers={"Authorization": f"Bearer {t}", "Content-Type": "application/json"})
            urllib.request.urlopen(req).read()
