# The liveness probe needs no auth.
GET {{url}}/api/healthcheck
HTTP 200
[Asserts]
body == "Ok"

# Calling /api/data without an auth token must be rejected.
POST {{url}}/api/data
{"lastSyncedId":0,"data":[]}
HTTP 401
