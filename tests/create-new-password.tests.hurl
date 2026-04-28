# Apply a new password using the reset code from forgot-password.
#
# The runner must supply `reset_code` (e.g. `--variable reset_code=<jwt>`).
# In `--dev` mode the JWT can be pulled from the server's stderr, where
# TrailBase logs the would-be email body. The field name on the wire is
# `password_reset_code`; the server also accepts `password_reset_token` as
# an alias.
#
# We deliberately set the "new" password to the existing one so subsequent
# test runs and login.hurl keep working without touching local.env.

POST {{url}}/api/auth/v1/reset_password/update
Content-Type: application/json
{
  "password_reset_code": "{{reset_code}}",
  "password": "{{password}}",
  "password_repeat": "{{password}}"
}
HTTP 200

# Confirm the password works by logging in fresh.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{ "email": "{{email}}", "password": "{{password}}" }
HTTP 200
[Asserts]
jsonpath "$.auth_token" exists
