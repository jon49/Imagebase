POST {{url}}/api/authentication/login
[Form]
email:
password: {{password}}
HTTP 400

POST {{url}}/api/authentication/login
[Form]
email: {{email}}
password:
HTTP 400
