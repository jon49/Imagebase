# Calling /api/data without an auth token must be rejected.
POST {{url}}/api/data
{"lastSyncedId":0,"data":[]}
HTTP 401
