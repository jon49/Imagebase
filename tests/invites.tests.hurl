# Space membership + invite routes. Depends on `{{token}}` (user A, `{{email}}`)
# and `{{token_b}}` (user B), neither in any `invite-test` space beforehand.

# 1. A creates a space and is its only member.
POST {{url}}/api/spaces/invite-test
Authorization: Bearer {{token}}
HTTP 200
[Captures]
space: jsonpath "$.space"
[Asserts]
jsonpath "$.space" matches /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

GET {{url}}/api/spaces/invite-test/{{space}}/members
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].email" == "{{email}}"
jsonpath "$.members[0].me" == true

# 2. The new space shows up in A's sync, not B's; B can't see its members.
POST {{url}}/api/data/invite-test
Authorization: Bearer {{token}}
{}
HTTP 200
[Asserts]
jsonpath "$.spaces['{{space}}']" isInteger

POST {{url}}/api/data/invite-test
Authorization: Bearer {{token_b}}
{}
HTTP 200
[Asserts]
body contains "\"spaces\":{}"

GET {{url}}/api/spaces/invite-test/{{space}}/members
Authorization: Bearer {{token_b}}
HTTP 404

# A space id is scoped to its app.
GET {{url}}/api/spaces/other-app/{{space}}/members
Authorization: Bearer {{token}}
HTTP 404

# 3. A invites. Accepting your own invite is a no-op that leaves it usable.
POST {{url}}/api/spaces/invite-test/{{space}}/invites
Authorization: Bearer {{token}}
HTTP 200
[Captures]
code: jsonpath "$.code"
[Asserts]
jsonpath "$.expires" isInteger

POST {{url}}/api/invites/invite-test/{{code}}/accept
Authorization: Bearer {{token}}
HTTP 200
[Asserts]
jsonpath "$.space" == "{{space}}"

# 4. B previews the invite without consuming it.
GET {{url}}/api/invites/invite-test/{{code}}
Authorization: Bearer {{token_b}}
HTTP 200
[Asserts]
jsonpath "$.space" == "{{space}}"
jsonpath "$.invitedBy" == "{{email}}"
jsonpath "$.member" == false

# The code is only valid under its own app.
POST {{url}}/api/invites/other-app/{{code}}/accept
Authorization: Bearer {{token_b}}
HTTP 404

# 5. B accepts; the code is then spent.
POST {{url}}/api/invites/invite-test/{{code}}/accept
Authorization: Bearer {{token_b}}
HTTP 200
[Asserts]
jsonpath "$.space" == "{{space}}"

POST {{url}}/api/invites/invite-test/{{code}}/accept
Authorization: Bearer {{token_b}}
HTTP 404

GET {{url}}/api/spaces/invite-test/{{space}}/members
Authorization: Bearer {{token_b}}
HTTP 200
[Captures]
a_id: jsonpath "$.members[?(@.me == false)].user"
b_id: jsonpath "$.members[?(@.me == true)].user"
[Asserts]
jsonpath "$.members" count == 2

# B's next sync picks the space up with nothing pulled yet.
POST {{url}}/api/data/invite-test
Authorization: Bearer {{token_b}}
{}
HTTP 200
[Asserts]
jsonpath "$.spaces['{{space}}']" isInteger

# 6. Equal rights: B can invite too. Then A removes B, which revokes B's invite
#    so B can't use it to let themselves back in.
POST {{url}}/api/spaces/invite-test/{{space}}/invites
Authorization: Bearer {{token_b}}
HTTP 200
[Captures]
code_b: jsonpath "$.code"

DELETE {{url}}/api/spaces/invite-test/{{space}}/members/{{b_id}}
Authorization: Bearer {{token}}
HTTP 200

GET {{url}}/api/spaces/invite-test/{{space}}/members
Authorization: Bearer {{token_b}}
HTTP 404

POST {{url}}/api/invites/invite-test/{{code_b}}/accept
Authorization: Bearer {{token_b}}
HTTP 404

# A non-member can't remove anyone.
DELETE {{url}}/api/spaces/invite-test/{{space}}/members/{{a_id}}
Authorization: Bearer {{token_b}}
HTTP 404

# 7. Re-invite B. B then removes A (equal rights) and leaves, which deletes the
#    now memberless space.
POST {{url}}/api/spaces/invite-test/{{space}}/invites
Authorization: Bearer {{token}}
HTTP 200
[Captures]
code2: jsonpath "$.code"

POST {{url}}/api/invites/invite-test/{{code2}}/accept
Authorization: Bearer {{token_b}}
HTTP 200

DELETE {{url}}/api/spaces/invite-test/{{space}}/members/{{a_id}}
Authorization: Bearer {{token_b}}
HTTP 200

# Already gone.
DELETE {{url}}/api/spaces/invite-test/{{space}}/members/{{a_id}}
Authorization: Bearer {{token_b}}
HTTP 404

DELETE {{url}}/api/spaces/invite-test/{{space}}/members/me
Authorization: Bearer {{token_b}}
HTTP 200

POST {{url}}/api/data/invite-test
Authorization: Bearer {{token}}
{}
HTTP 200
[Asserts]
body contains "\"spaces\":{}"

# 8. Input validation and auth.
GET {{url}}/api/spaces/invite-test/not-a-uuid/members
Authorization: Bearer {{token}}
HTTP 400

GET {{url}}/api/invites/invite-test/not-a-uuid
Authorization: Bearer {{token}}
HTTP 400

POST {{url}}/api/spaces/invite-test
HTTP 401
