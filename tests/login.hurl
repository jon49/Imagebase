# Exchanges credentials for an auth token. The token is captured into a file
# so follow-up test files can read it via `--variable token=$(cat ...)`.
POST {{url}}/api/auth/v1/login
Content-Type: application/json
{
  "email": "{{email}}",
  "password": "{{password}}"
}
HTTP 200
[Captures]
auth_token: jsonpath "$.auth_token"
[Asserts]
jsonpath "$.auth_token" exists
