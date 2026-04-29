# Negative-path validation: malformed payloads should be rejected.

POST {{url}}/api/data/test
Authorization: Bearer {{token}}
{ "lastSyncedId": -1 }
HTTP 400

POST {{url}}/api/data/test
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [{ "key": "", "data": null, "id": 0 }] }
HTTP 400
