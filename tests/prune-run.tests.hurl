# Triggers the `prune_overwritten_data` cron job on demand via TrailBase's
# admin API (the same endpoint the admin dashboard's "run now" button calls),
# proving the job is registered and runnable without waiting for its schedule.
#
# Admin endpoints require an admin user plus a matching CSRF token, so the
# runner promotes the test user to admin and passes a fresh `{{token}}` /
# `{{csrf}}` captured after that promotion.

# List the registered jobs and grab the numeric id of ours. The id is assigned
# at startup and isn't stable, so we look it up by name rather than hard-code it.
GET {{url}}/api/_admin/jobs
Authorization: Bearer {{token}}
CSRF-Token: {{csrf}}
HTTP 200
[Captures]
job_id: jsonpath "$.jobs[?(@.name=='prune_overwritten_data')].id"
[Asserts]
# A single filter match is unwrapped to a scalar, so check the id directly.
jsonpath "$.jobs[?(@.name=='prune_overwritten_data')].id" exists

# Run it now. A successful run reports a null error; the runner then asserts the
# actual row deletions directly against the database.
POST {{url}}/api/_admin/job/run
Authorization: Bearer {{token}}
CSRF-Token: {{csrf}}
Content-Type: application/json
{ "id": {{job_id}} }
HTTP 200
[Asserts]
jsonpath "$.error" == null
