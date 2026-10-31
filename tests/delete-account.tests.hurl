# Self-service account deletion via TrailBase's `DELETE /api/auth/v1/delete`.
# Uses a dedicated, already registered + verified user (`{{email_c}}`) since it
# doesn't survive the test. The runner checks the leftover DB state afterwards.

POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email_c}}", "password": "{{password}}" }
HTTP 200
[Captures]
auth_token: jsonpath "$.auth_token"
refresh_token: jsonpath "$.refresh_token"

# Give the user something to clean up: a personal row and a space of their own.
POST {{url}}/api/data/delete-test
Authorization: Bearer {{auth_token}}
{ "lastSyncedId": 0, "data": [ { "key": "doomed", "data": { "v": 1 } } ] }
HTTP 200
[Asserts]
jsonpath "$.saved" count == 1

POST {{url}}/api/spaces/delete-test
Authorization: Bearer {{auth_token}}
HTTP 200

# Only DELETE deletes.
POST {{url}}/api/auth/v1/delete
Authorization: Bearer {{auth_token}}
HTTP 405

DELETE {{url}}/api/auth/v1/delete
Authorization: Bearer {{auth_token}}
HTTP 200

# The JWT itself stays valid until it expires, but the guest routes must now
# reject it outright: reads as well as writes, and with 401 rather than a 500
# from the `_user` foreign keys.
POST {{url}}/api/data/delete-test
Authorization: Bearer {{auth_token}}
{ "lastSyncedId": 0 }
HTTP 401

POST {{url}}/api/data/delete-test
Authorization: Bearer {{auth_token}}
{ "lastSyncedId": 0, "data": [ { "key": "zombie", "data": { "v": 2 } } ] }
HTTP 401

POST {{url}}/api/spaces/delete-test
Authorization: Bearer {{auth_token}}
HTTP 401

# Deletion ended the sessions, so the token can't be refreshed either...
POST {{url}}/api/auth/v1/refresh
Content-Type: application/json
{ "refresh_token": "{{refresh_token}}" }
HTTP 401

# ...and the credentials no longer log in.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email_c}}", "password": "{{password}}" }
HTTP 401
