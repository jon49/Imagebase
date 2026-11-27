# After the prune deleted two expired pages (tests.sh aged their files), the
# old links are gone, but only whoever could write a page before may
# republish to its link. Depends on `{{token}}` (the page owner) and
# `{{token_b}}` (a member of space 55555555-…).

GET {{url}}/api/pages/11111111-1111-1111-1111-111111111111
HTTP 404

# The owner's expired page stays the owner's: B can't claim its id for a space.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "space": "55555555-5555-5555-5555-555555555555",
  "html": { "filename": "x.html", "content_type": "text/html", "data": "PGgxPkhJSkFDSzwvaDE+" }
}
HTTP 403

# A member of the expired page's space can bring it back at the same link.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token_b}}
Content-Type: application/json
{
  "id": "88888888-8888-8888-8888-888888888888",
  "space": "55555555-5555-5555-5555-555555555555",
  "html": { "filename": "s.html", "content_type": "text/html", "data": "PGgxPkJBQ0s8L2gxPg==" }
}
HTTP 200

GET {{url}}/api/pages/88888888-8888-8888-8888-888888888888
HTTP 200
[Asserts]
body contains "BACK"

# And the owner can republish theirs.
POST {{url}}/api/records/v1/pages
Authorization: Bearer {{token}}
Content-Type: application/json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "html": { "filename": "x.html", "content_type": "text/html", "data": "PGgxPlBVQkxJU0hFRC1WMzwvaDE+" }
}
HTTP 200

GET {{url}}/api/pages/11111111-1111-1111-1111-111111111111
HTTP 200
[Asserts]
body contains "PUBLISHED-V3"
