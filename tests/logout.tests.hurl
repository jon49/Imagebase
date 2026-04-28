# Logout against TrailBase's stateless JWT model.
#
# Important: POST /logout deletes the *session row* keyed on refresh_token,
# but the auth_token (JWT) it was paired with stays valid until its TTL
# expires (auth_token_ttl_sec in config.textproto, default 1h). So we cannot
# prove logout worked by re-hitting /api/data with the same access token —
# we have to prove it via /refresh, which now finds no matching session.

# Login to obtain a fresh, isolated session for this test.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email}}", "password": "{{password}}" }
HTTP 200
[Captures]
auth_token: jsonpath "$.auth_token"
refresh_token: jsonpath "$.refresh_token"

# Sanity check: the access token works against the protected endpoint.
POST {{url}}/api/data
Authorization: Bearer {{auth_token}}
{ "lastSyncedId": 0 }
HTTP 200

# Log this session out.
POST {{url}}/api/auth/v1/logout
Content-Type: application/json
{ "refresh_token": "{{refresh_token}}" }
HTTP 200

# The refresh token can no longer be exchanged for a new access token.
POST {{url}}/api/auth/v1/refresh
Content-Type: application/json
{ "refresh_token": "{{refresh_token}}" }
HTTP 401
