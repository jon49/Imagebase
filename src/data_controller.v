module main

import data
import db.sqlite
import utils { parse_json }
import validation
import veb

struct SyncDataDto {
	last_synced_id int @[json: lastSyncedId]
	data           []DataDto
}

pub struct DataDto {
pub:
	key  string  @[raw]
	data ?string @[raw]
	id   int
}

pub struct SavedDto {
pub:
	key string
	id  i64
}

pub struct ConflictedDto {
pub:
	key       string
	data      ?string @[raw]
	id        int
	timestamp string
}

pub struct SyncDataReturnDto {
pub:
	data           []DataDto
	saved          []SavedDto
	conflicted     []ConflictedDto
	last_synced_id i64 @[json: lastSyncedId]
}

@['/api/data'; post]
fn (mut app App) sync_data(mut ctx Context) veb.Result {
	result := sync_data(&app.db, ctx.user_id, ctx.req.data) or { return ctx.message_response(err) }

	return ctx.json(result)
}

fn sync_data(db &sqlite.DB, user_id int, json_data string) !SyncDataReturnDto {
	data_dto := parse_json[SyncDataDto](json_data)!
	validate_sync_data_dto(&data_dto)!

	data_arr := data_dto.data.map(data.SimpleData{
		key:   it.key
		value: it.data or { '' }
		id:    it.id
	})
	d := &data.SyncData{
		user_id:       user_id
		last_id:       data_dto.last_synced_id
		uploaded_data: data_arr
	}

	result := data.sync_data(db, d)!

	return SyncDataReturnDto{
		data:           result.new_user_data.map(DataDto{
			key:  it.key
			data: option(it.value)
			id:   it.id
		})
		saved:          result.saved.map(SavedDto{
			key: it.key
			id:  it.id
		})
		conflicted:     result.conflicted_data.map(ConflictedDto{
			key:       it.key
			data:      option(it.value)
			id:        it.id
			timestamp: it.timestamp
		})
		last_synced_id: max(result.last_synced_id, data_dto.last_synced_id)
	}
}

fn max(a i64, b i64) i64 {
	if a > b {
		return a
	}
	return b
}

fn option(value string) ?string {
	if value.len == 0 {
		return none
	}
	return value
}

fn validate_sync_data_dto(sync_data &SyncDataDto) ! {
	mut v := validation.start()
	v.validate(sync_data.last_synced_id > -1, 'Last Sync ID must be whole number but is "${sync_data.last_synced_id}".')
	mut i := 0
	for d in sync_data.data {
		v.validate(d.key.len > 0, 'Key [${i}] is required.')
		i++
	}
	v.result()!
}
