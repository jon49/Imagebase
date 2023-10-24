module main

import rand
import time
import validation

[table: 'sessions']
struct Session {
	id           int       [primary; sql: serial]
	user_id      int
	session      string    [unique]
	created_date time.Time
}

fn (mut app App) create_session(user_id int) !Session {
	uuid := rand.uuid_v4()
	session := Session{
		user_id: user_id
		session: uuid
		created_date: time.now()
	}

	sql app.session_db {
		insert session into Session
	}!

	return session
}

fn (mut app App) login(email string, password string) !Session {
	mut v := validation.start()
	v.validate(email.len > 0, 'Email cannot be empty.')
	v.validate(password.len > 0, 'Password cannot be empty.')
	v.result()!

	user_id := app.get_user_id(email, password)!

	return app.create_session(user_id)
}

fn (mut app App) delete_session() ! {
	mut v := validation.start()
	v.validate(app.session.len == 0, 'No session available.')
	v.result()!

	sql app.session_db {
		delete from Session where session == app.session
	}!
}

fn (mut app App) register(email string, password string) !string {
	user_id := app.register_new_user(email, password)!
	if user_id == 0 {
		return error("Oops, something happened that shouldn't have. Could not create user!")
	}

	session := app.create_session(user_id)!
	return session.session
}
