# Trigger a password-reset email. The reset code is a JWT delivered to the
# user's inbox; in `--dev` mode it's also written to the server's stderr as
# part of the "[dev] Skip sending email" log line.
#
# TrailBase rate-limits this endpoint to ~1/hour per email and returns 429
# on the second hit within that window. We accept either 200 or 429 so the
# test stays rerun-safe — the assertion still tightens the response surface
# (no 4xx/5xx like 400 or 500 sneaks through).
POST {{url}}/api/auth/v1/reset_password/request
Content-Type: application/json
{ "email": "{{email}}" }
HTTP *
[Asserts]
status toString matches /^(200|429)$/
