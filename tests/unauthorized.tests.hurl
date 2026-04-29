# Calling /api/data without an auth token must be rejected.
POST {{url}}/api/data/test
{"lastSyncedId":0,"data":[]}
HTTP 401
