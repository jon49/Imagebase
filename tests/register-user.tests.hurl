POST {{url}}/api/authentication/register
[Form]
email: {{email}}
password: {{password}}
HTTP 200
[Asserts]
cookie "session" exists
