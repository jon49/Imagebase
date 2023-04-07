module notes

import db.sqlite
import msg { validate, assert_found, has_content }

const (
	unique_message = 'Please provide a unique message for Note'
    invalid_json = 'Malformed JSON received.'
)

[table: 'notes']
pub struct Note {
pub:
	id      int    [primary; sql: serial]
	message string [sql: 'detail'; unique]
	status  bool   [nonull]
}

pub fn create(mut db &sqlite.DB, data string) !Note {
    note := msg.get_data[Note](data)!

	// before we save, we must ensure the note's message is unique
	notes_found := sql db {
		select from Note where message == note.message
	}!

    validate(notes_found.len == 0, unique_message)!

	// save to db
	sql db {
		insert note into Note
	}!

	// retrieve the last id from the db to build full Note object
	new_id := db.last_id() as int

	// build new note object including the new_id and send it as JSON response
	created_note := Note{new_id, note.message, note.status}
    return created_note
}

pub fn get(db &sqlite.DB, id int) !Note {
	note := sql db {
		select from Note where id == id
	}!

    assert_found(note.len, 'note')!

    return note[0]
}

pub fn get_all(db &sqlite.DB) ![]Note {
	n := sql db {
		select from Note
	}!

    has_content(n.len)!

    return n
}

pub fn update(mut db &sqlite.DB, id int, data string) !Note {
    n := msg.get_data[Note](data)!

	note_to_update := sql db {
		select from Note
        where id == id
        limit 1
	}!

    assert_found(note_to_update.len, 'note')!

	res := sql db {
		select from Note where message == n.message && id != id limit 1
	}!

    validate(res.len == 0, 'Duplicate notes not allowed!')!

	sql db {
		update Note set message = n.message, status = n.status where id == id
	}!

	updated_note := Note{id, n.message, n.status}

    return updated_note
}

pub fn delete(mut db &sqlite.DB, id int) !IError {
    validate(id > 0, 'Invalid ID — ${id}.')!

	sql db {
		delete from Note where id == id
	}!

	return msg.success()
}

