POST  {{url}}/api/authentication/reset-password
[Form]
token: {{reset_token}}
password: "new password"
passwordConfirm: "new password"
HTTP 204

POST {{url}}/api/authentication/login
[Form]
email: {{email}}
password: "new password"
HTTP 200
