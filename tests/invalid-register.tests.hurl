POST {{url}}/api/authentication/register
{
  "email":    "",
  "password": "password"
}
HTTP 400

POST {{url}}/api/authentication/register
{
	"email": "test@test.com",
	"password": ""
}
HTTP 400
