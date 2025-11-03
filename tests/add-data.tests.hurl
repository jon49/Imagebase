# Add data and sync tests

# Initial data addition
POST {{url}}/api/data
{
  "lastSyncId": 0,
  "data": [{
      "key": [1, "test-key"],
      "data": { "my": "data", "is": "here" },
      "id": 0 }, {
      "key": "test-key2",
      "data": { "my": "data2", "is": "here2" },
      "id": 0 }
  ]
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.data" count == 0
jsonpath "$.saved" count == 2
jsonpath "$.saved[0].key" == "[1,\"test-key\"]"
jsonpath "$.saved[0].id" == 1
jsonpath "$.saved[1].key" == "\"test-key2\""
jsonpath "$.saved[1].id" == 2
jsonpath "$.conflicted" count == 0
jsonpath "$.lastSyncedId" == 2

# Sync with one conflict
POST {{url}}/api/data
{ "lastSyncedId": 1,
  "data": [{
      "key": "test-key2",
      "data": { "my": "data", "is": "here" },
      "id": 0 } ]
}
HTTP 200
[Asserts]
jsonpath "$.lastSyncedId" == 3
jsonpath "$.data" count == 0
jsonpath "$.saved" count == 1
jsonpath "$.saved[0].key" == "\"test-key2\""
jsonpath "$.saved[0].id" == 3
jsonpath "$.conflicted" count == 1
jsonpath "$.conflicted[0].key" == "\"test-key2\""
jsonpath "$.conflicted[0].id" == 2
jsonpath "$.conflicted[0].data" == "{\"my\":\"data2\",\"is\":\"here2\"}"

# Sync to get all new data
POST {{url}}/api/data
{ "lastSyncedId": 0 }
HTTP 200
[Asserts]
jsonpath "$.lastSyncedId" == 3
jsonpath "$.data" count == 2
jsonpath "$.data[0].key" == "[1,\"test-key\"]"
jsonpath "$.data[0].data" == "{\"my\":\"data\",\"is\":\"here\"}"
jsonpath "$.data[0].id" == 1
jsonpath "$.data[1].key" == "\"test-key2\""
jsonpath "$.data[1].data" == "{\"my\":\"data\",\"is\":\"here\"}"
jsonpath "$.data[1].id" == 3
jsonpath "$.saved" count == 0
jsonpath "$.conflicted" count == 0

# Syncing when there is no new data on the back end.
POST {{url}}/api/data
{ "lastSyncedId": 3 }
HTTP 200
[Asserts]
jsonpath "$.lastSyncedId" == 3
jsonpath "$.data" count == 0
jsonpath "$.saved" count == 0
jsonpath "$.conflicted" count == 0
