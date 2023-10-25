module main

import db.sqlite
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

[table: 'password_reset']
struct PasswordReset {
	id           int    [primary; sql: serial]
	user_id      int
	token        string [unique]
	created_date string [default: 'CURRENT_TIMESTAMP'; sql_type: 'DATETIME']
}

fn create_session_db(session_db &sqlite.DB) ! {
	sql session_db {
		create table Session
	}!
	sql session_db {
		create table PasswordReset
	}!
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

fn forgot_password(user_db &sqlite.DB, session_db &sqlite.DB, email string) ! {
	mut v := validation.start()
	v.validate(email.len > 0, 'Email cannot be empty.')
	v.result()!

	user := sql user_db {
		select from User where email == email limit 1
	}!
	if user.len == 0 {
		return
	}

	user_id := user[0].id

	// Create a password reset token
	uuid := rand.uuid_v4()
	password_reset := PasswordReset{
		user_id: user_id
		token: uuid
	}

	sql session_db {
		insert password_reset into PasswordReset
	}!
}

fn (mut app App) delete_session() ! {
	mut v := validation.start()
	v.validate(app.session.len > 0, 'No session available.')
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
