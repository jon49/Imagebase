# The liveness probe needs no auth.
GET {{url}}/api/healthcheck
HTTP 200
[Asserts]
body == "Ok"

# The multi-app server's sync path, with an app id, is gone.
POST {{url}}/api/data/soccer
{"lastSyncedId":0}
HTTP 404

# Calling /api/data without an auth token must be rejected.
POST {{url}}/api/data
{"lastSyncedId":0,"data":[]}
HTTP 401
