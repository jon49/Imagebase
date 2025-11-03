POST {{url}}/api/authentication/login
[Form]
email: {{email}}
password: {{password}}
HTTP 200
[Asserts]
cookie "session" exists
