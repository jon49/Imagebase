import { defineConfig, urlSafeBase64Decode } from "trailbase-wasm";
import {
  HttpHandler,
  HttpRequest,
  HttpResponse,
  HttpError,
  StatusCode,
} from "trailbase-wasm/http";
import { Transaction } from "trailbase-wasm/db";

type IncomingItem = { key: unknown; data?: unknown; id?: number };
type SyncRequest = { lastSyncedId?: number; data?: IncomingItem[] };

type Saved = { key: string; id: number };
type Entry = { key: string; data: string | null; id: number };
type Conflict = Entry & { timestamp: string };

async function syncData(req: HttpRequest): Promise<HttpResponse> {
  const user = req.user();
  if (!user) {
    throw new HttpError(StatusCode.UNAUTHORIZED, "Unauthorized");
  }

  const body = (req.json() ?? {}) as SyncRequest;
  const lastSyncedId =
    typeof body.lastSyncedId === "number" ? body.lastSyncedId : 0;
  const incoming = Array.isArray(body.data) ? body.data : [];

  if (!Number.isInteger(lastSyncedId) || lastSyncedId < 0) {
    throw new HttpError(
      StatusCode.BAD_REQUEST,
      `Last Sync ID must be whole number but is "${lastSyncedId}".`,
    );
  }
  incoming.forEach((item, i) => {
    if (item.key === undefined || item.key === null || item.key === "") {
      throw new HttpError(StatusCode.BAD_REQUEST, `Key [${i}] is required.`);
    }
  });

  const userId = urlSafeBase64Decode(user.id);

  const tx = new Transaction();
  try {
    // Rows written by any client since the cursor, deduplicated by key keeping
    // the most recent write. Matches the semantics of the original V server.
    const latestRows = tx.query(
      `WITH duplicates AS (
         SELECT id, key, value, timestamp,
                ROW_NUMBER() OVER (PARTITION BY user, key ORDER BY id DESC) AS dup
         FROM user_data
         WHERE id > $1 AND user = $2
       )
       SELECT key, value, id, timestamp
       FROM duplicates
       WHERE dup = 1
       ORDER BY id`,
      [BigInt(lastSyncedId), userId],
    );

    // Keys arriving in this batch (serialised the same way we store them) so
    // we can partition `latest` into "new since last sync" vs "conflicting
    // with an incoming write".
    const uploadedKeys = new Set(
      incoming.map((item) => JSON.stringify(item.key)),
    );

    const data: Entry[] = [];
    const conflicted: Conflict[] = [];
    for (const row of latestRows) {
      const key = row[0] as string;
      const value = row[1] as string | null;
      const id = Number(row[2]);
      const timestamp = row[3] as string;
      if (uploadedKeys.has(key)) {
        conflicted.push({ key, data: value, id, timestamp });
      } else {
        data.push({ key, data: value, id });
      }
    }

    const saved: Saved[] = [];
    for (const item of incoming) {
      const key = JSON.stringify(item.key);
      const value =
        item.data === undefined || item.data === null
          ? null
          : JSON.stringify(item.data);
      const inserted = tx.query(
        `INSERT INTO user_data (user, key, value)
         VALUES ($1, $2, $3)
         RETURNING id`,
        [userId, key, value],
      );
      saved.push({ key, id: Number(inserted[0][0]) });
    }

    tx.commit();

    const maxLatest = latestRows.reduce(
      (m, r) => Math.max(m, Number(r[2])),
      0,
    );
    const maxSaved = saved.reduce((m, s) => Math.max(m, s.id), 0);

    return HttpResponse.json({
      data,
      saved,
      conflicted,
      lastSyncedId: Math.max(lastSyncedId, maxLatest, maxSaved),
    });
  } catch (err) {
    tx.rollback();
    throw err;
  }
}

export default defineConfig({
  httpHandlers: [HttpHandler.post("/api/data", syncData)],
});
