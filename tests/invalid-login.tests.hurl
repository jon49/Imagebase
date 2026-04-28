# Negative-path checks for /api/auth/v1/login. TrailBase intentionally returns
# the same 401 for "wrong password", "unknown email", and "missing user" so
# attackers cannot enumerate accounts via the login endpoint.
#
# After enough failed credential checks, TrailBase's anti-bruteforce limiter
# starts returning 429 instead of 401. We accept either so reruns stay green.
# The empty-email case is rejected upstream as malformed input (400) and is
# not subject to that limiter.

# Empty email — fails input validation before the credential check.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "", "password": "{{password}}" }
HTTP 400

# Empty password — passes input validation, fails the credential check.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email}}", "password": "" }
HTTP *
[Asserts]
status toString matches /^(401|429)$/

# Wrong password for an existing user.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email}}", "password": "totally-wrong" }
HTTP *
[Asserts]
status toString matches /^(401|429)$/

# Unknown email — same vague 401, no body shape difference from above.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "nobody@example.com", "password": "{{password}}" }
HTTP *
[Asserts]
status toString matches /^(401|429)$/
