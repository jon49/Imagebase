# The multi-app server's paths carried an app id (/api/data/{app},
# /api/pages/{app}/{id}, ...). Installed clients and already-shared page links
# still use them, so the server drops that segment and serves the current
# route. Depends on `{{token}}` (the page owner).

# Sync by the old path.
POST {{url}}/api/data/soccer
Authorization: Bearer {{token}}
{ "lastSyncedId": 0, "data": [ { "key": "legacy-path", "data": 1 } ] }
HTTP 200
[Asserts]
jsonpath "$.saved[0].key" == "\"legacy-path\""

# A page upload that still names its app: the field is ignored.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token}}
Content-Type: application/json
{
  "id": "aaaaaaaa-0000-4000-8000-000000000001",
  "app": "soccer",
  "html": { "filename": "legacy.html", "content_type": "text/html", "data": "PGgxPkxFR0FDWTwvaDE+" }
}
HTTP 200

# Shared links of both shapes serve it.
GET {{url}}/api/pages/soccer/aaaaaaaa-0000-4000-8000-000000000001
HTTP 200
[Asserts]
header "Content-Type" contains "text/html"
body contains "LEGACY"

GET {{url}}/api/pages/aaaaaaaa-0000-4000-8000-000000000001
HTTP 200
[Asserts]
body contains "LEGACY"

# Space routes by the old paths: create, invite, leave.
POST {{url}}/api/spaces/soccer
Authorization: Bearer {{token}}
HTTP 200
[Captures]
space: jsonpath "$.space"

POST {{url}}/api/spaces/soccer/{{space}}/invites
Authorization: Bearer {{token}}
HTTP 200
[Captures]
code: jsonpath "$.code"

POST {{url}}/api/invites/soccer/{{code}}/accept
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.space" == "{{space}}"

DELETE {{url}}/api/spaces/soccer/{{space}}/members/me
Authorization: Bearer {{token}}
HTTP 200

GET {{url}}/api/spaces/{{space}}/members
Authorization: Bearer {{token}}
HTTP 404
