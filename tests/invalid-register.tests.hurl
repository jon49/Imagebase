# Negative-path checks for /api/auth/v1/register. The server rejects invalid
# payloads with 400 *before* touching the database, so these calls do not
# pollute the _user table even on repeated runs.

# Mismatched password / password_repeat.
POST {{url}}/api/auth/v1/register
Content-Type: application/json
{
  "email": "throwaway@example.com",
  "password": "{{password}}",
  "password_repeat": "different-password"
}
HTTP 400

# Empty email — fails the `is_email` CHECK on the _user table.
POST {{url}}/api/auth/v1/register
Content-Type: application/json
{
  "email": "",
  "password": "{{password}}",
  "password_repeat": "{{password}}"
}
HTTP 400

# Empty password — fails the password policy (8+ characters).
POST {{url}}/api/auth/v1/register
Content-Type: application/json
{
  "email": "throwaway@example.com",
  "password": "",
  "password_repeat": ""
}
HTTP 400
