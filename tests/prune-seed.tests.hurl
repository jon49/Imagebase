# Seeds overwrite history for the nightly prune job under a dedicated app id
# (`prune`) so it can't collide with the other sync tests. Depends on
# `{{token}}` being set by the runner.
#
# Two keys, each written twice:
#   "old"    -> the runner ages the older row past the retention window, so the
#               prune job should delete it and keep only the latest.
#   "recent" -> both writes stay inside the window, so the prune job must keep
#               both even though the older one is an overwrite.

# key "old", first (soon-to-be-overwritten) value.
POST {{url}}/api/data/prune
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [ { "key": "old", "data": { "v": 1 }, "id": 0 } ] }
HTTP 200
[Asserts]
jsonpath "$.saved" count == 1

# key "old", overwriting value (this one is the latest and must survive).
POST {{url}}/api/data/prune
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [ { "key": "old", "data": { "v": 2 }, "id": 0 } ] }
HTTP 200
[Asserts]
jsonpath "$.saved" count == 1

# key "recent", first value (an overwrite, but recent -> retained).
POST {{url}}/api/data/prune
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [ { "key": "recent", "data": { "v": 1 }, "id": 0 } ] }
HTTP 200
[Asserts]
jsonpath "$.saved" count == 1

# key "recent", overwriting value.
POST {{url}}/api/data/prune
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [ { "key": "recent", "data": { "v": 2 }, "id": 0 } ] }
HTTP 200
[Asserts]
jsonpath "$.saved" count == 1
