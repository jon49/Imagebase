# Publish-an-HTML-page flow. Depends on `{{token}}` (the page owner, set by
# tests.sh with `imagebase owner set`) and `{{token_b}}` (another user).

# 1. Owner publishes a page. `id` is a client-supplied GUID stored verbatim.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token}}
Content-Type: application/json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "html": {
    "filename": "index.html",
    "content_type": "text/html",
    "data": "PCFkb2N0eXBlIGh0bWw+PG1ldGEgY2hhcnNldD0idXRmLTgiPjx0aXRsZT5JbWFnZUJhc2U8L3RpdGxlPjxoMT5QVUJMSVNIRUQtVjE8L2gxPg=="
  }
}
HTTP 200

# 2. Anyone (no auth) fetches it, rendered inline as HTML.
GET {{url}}/api/pages/11111111-1111-1111-1111-111111111111
HTTP 200
[Asserts]
header "Content-Type" contains "text/html"
header "Content-Disposition" not exists
body contains "PUBLISHED-V1"

# 3. Owner overwrites the same GUID (REPLACE conflict resolution).
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token}}
Content-Type: application/json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "html": {
    "filename": "index.html",
    "content_type": "text/html",
    "data": "PCFkb2N0eXBlIGh0bWw+PG1ldGEgY2hhcnNldD0idXRmLTgiPjx0aXRsZT5JbWFnZUJhc2U8L3RpdGxlPjxoMT5QVUJMSVNIRUQtVjI8L2gxPg=="
  }
}
HTTP 200

# 4. The fetch now reflects the overwrite.
GET {{url}}/api/pages/11111111-1111-1111-1111-111111111111
HTTP 200
[Asserts]
body contains "PUBLISHED-V2"
body not contains "PUBLISHED-V1"

# 5. Unknown page id -> 404.
GET {{url}}/api/pages/22222222-2222-2222-2222-222222222222
HTTP 404

# 6. No auth token -> rejected by the Record API ACL.
POST {{url}}/api/records/v1/pages
Content-Type: application/json
{
  "id": "33333333-3333-3333-3333-333333333333",
  "html": { "filename": "x.html", "content_type": "text/html", "data": "PGgxPm5vPC9oMT4=" }
}
HTTP 403

# 7. Valid token, but the caller is not the page owner and names no space.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "44444444-4444-4444-4444-444444444444",
  "html": { "filename": "x.html", "content_type": "text/html", "data": "PGgxPm5vPC9oMT4=" }
}
HTTP 403
