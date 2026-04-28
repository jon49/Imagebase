# Register the canonical test user. TrailBase returns 200 whether the user is
# newly created or already exists — this privacy-preserving behaviour prevents
# attackers from enumerating registered emails. The runner relies on that
# property to make the step idempotent across repeated test runs.
POST {{url}}/api/auth/v1/register
Content-Type: application/json
{
  "email": "{{email}}",
  "password": "{{password}}",
  "password_repeat": "{{password}}"
}
HTTP 200
