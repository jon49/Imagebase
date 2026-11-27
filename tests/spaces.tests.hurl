# Shared spaces: two users syncing one slice of data as equals. Depends on
# `{{token}}` (user A) and `{{token_b}}` (user B), with spaces seeded by tests.sh:
#   55555555-…  members A, B
#   66666666-…  members A
# A's personal rows are wiped first, so A's own data here is only what this
# file writes.

# 1. A writes one personal row and one row into the shared space.
POST {{url}}/api/data
Authorization: Bearer {{token}}
{
  "lastSyncedId": 0,
  "data": [
    { "key": "mine", "data": { "who": "a" } },
    { "key": ["team", 1], "data": { "v": 1 }, "space": "55555555-5555-5555-5555-555555555555" }
  ]
}
HTTP 200
[Captures]
a_s1: jsonpath "$.spaces['55555555-5555-5555-5555-555555555555']"
[Asserts]
jsonpath "$.saved" count == 2
jsonpath "$.saved[0].space" not exists
jsonpath "$.saved[1].key" == "[\"team\",1]"
jsonpath "$.saved[1].space" == "55555555-5555-5555-5555-555555555555"
jsonpath "$.spaces['55555555-5555-5555-5555-555555555555']" isInteger
jsonpath "$.spaces['66666666-6666-6666-6666-666666666666']" == 0

# 2. B's first sync: gets the shared row (cursor defaults to 0 for an
#    unlisted space), but none of A's personal data and nothing from 66666666.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "lastSyncedId": 0 }
HTTP 200
[Captures]
b_s1: jsonpath "$.spaces['55555555-5555-5555-5555-555555555555']"
[Asserts]
jsonpath "$.data" count == 1
jsonpath "$.data[0].key" == "[\"team\",1]"
jsonpath "$.data[0].data" == "{\"v\":1}"
jsonpath "$.data[0].space" == "55555555-5555-5555-5555-555555555555"
jsonpath "$.lastSyncedId" == 0
jsonpath "$.spaces['66666666-6666-6666-6666-666666666666']" not exists

# 3. B edits the shared row as if it were B's own.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{
  "lastSyncedId": 0,
  "spaces": { "55555555-5555-5555-5555-555555555555": {{b_s1}} },
  "data": [
    { "key": ["team", 1], "data": { "v": 2 }, "space": "55555555-5555-5555-5555-555555555555" }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.conflicted" count == 0
jsonpath "$.saved" count == 1
jsonpath "$.saved[0].space" == "55555555-5555-5555-5555-555555555555"

# 4. A writes the same key from the stale cursor: B's write comes back as
#    conflicted (tagged with its space) and A's write wins (last write).
POST {{url}}/api/data
Authorization: Bearer {{token}}
{
  "lastSyncedId": 0,
  "spaces": { "55555555-5555-5555-5555-555555555555": {{a_s1}} },
  "data": [
    { "key": ["team", 1], "data": { "v": 3 }, "space": "55555555-5555-5555-5555-555555555555" }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.conflicted" count == 1
jsonpath "$.conflicted[0].data" == "{\"v\":2}"
jsonpath "$.conflicted[0].space" == "55555555-5555-5555-5555-555555555555"
# A's personal row from step 1 (cursor 0 re-pulls it); no space rows in `data`.
jsonpath "$.data" count == 1
jsonpath "$.data[0].key" == "\"mine\""

# 5. B writes a personal row whose key matches the shared one; they don't collide.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "lastSyncedId": 0, "data": [ { "key": ["team", 1], "data": { "b": "personal" } } ] }
HTTP 200
[Asserts]
jsonpath "$.saved[0].space" not exists
# The shared ["team",1] is in a different scope, so it's `data`, not `conflicted`.
jsonpath "$.conflicted" count == 0

# 6. Fresh pull for B: personal scope first, then each space.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "lastSyncedId": 0 }
HTTP 200
[Asserts]
jsonpath "$.data" count == 2
jsonpath "$.data[0].data" == "{\"b\":\"personal\"}"
jsonpath "$.data[0].space" not exists
jsonpath "$.data[1].data" == "{\"v\":3}"
jsonpath "$.data[1].space" == "55555555-5555-5555-5555-555555555555"

# 7. B is not a member of 66666666 -> the whole batch is refused.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{
  "lastSyncedId": 0,
  "data": [
    { "key": "x", "data": 1 },
    { "key": "y", "data": 1, "space": "66666666-6666-6666-6666-666666666666" }
  ]
}
HTTP 403

# 8. Malformed space ids.
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "data": [ { "key": "y", "data": 1, "space": "not-a-uuid" } ] }
HTTP 400

POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "spaces": { "55555555-5555-5555-5555-555555555555": -1 } }
HTTP 400

# 9. Step 7 wrote nothing, not even its personal "x": B's personal data is still
#     just the one row. (A huge space cursor just means "nothing new".)
POST {{url}}/api/data
Authorization: Bearer {{token_b}}
{ "lastSyncedId": 0, "spaces": { "55555555-5555-5555-5555-555555555555": 999999 } }
HTTP 200
[Asserts]
jsonpath "$.data" count == 1
jsonpath "$.data[0].data" == "{\"b\":\"personal\"}"

# --- Pages published by a space member (not the page owner) ---

# 10. B publishes a page for the shared space.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "88888888-8888-8888-8888-888888888888",
  "space": "55555555-5555-5555-5555-555555555555",
  "html": { "filename": "s.html", "content_type": "text/html", "data": "PGgxPlNIQVJFRDwvaDE+" }
}
HTTP 200

GET {{url}}/api/pages/88888888-8888-8888-8888-888888888888
HTTP 200
[Asserts]
body contains "SHARED"

# 11. A, also a member, overwrites it.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token}}
Content-Type: application/json
{
  "id": "88888888-8888-8888-8888-888888888888",
  "space": "55555555-5555-5555-5555-555555555555",
  "html": { "filename": "s.html", "content_type": "text/html", "data": "PGgxPlNIQVJFRC1BPC9oMT4=" }
}
HTTP 200

# 12. Not a member of that space.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "99999999-9999-9999-9999-999999999999",
  "space": "66666666-6666-6666-6666-666666666666",
  "html": { "filename": "s.html", "content_type": "text/html", "data": "PGgxPm5vPC9oMT4=" }
}
HTTP 403

# 13. REPLACE hijack: B may not overwrite a page outside B's space by reusing
#     its id (11111111-… was published by the page owner in publish-page).
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "space": "55555555-5555-5555-5555-555555555555",
  "html": { "filename": "s.html", "content_type": "text/html", "data": "PGgxPkhJSkFDSzwvaDE+" }
}
HTTP 403

GET {{url}}/api/pages/11111111-1111-1111-1111-111111111111
HTTP 200
[Asserts]
body not contains "HIJACK"
