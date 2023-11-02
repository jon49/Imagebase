module main

import db.sqlite
import msg
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
	id           int       [primary; sql: serial]
	user_id      int
	token        string    [unique]
	created_date time.Time
}

struct PasswordResetValues {
	user_db          &sqlite.DB
	session_db       &sqlite.DB
	salt             string
	token            string
	password         string
	password_confirm string
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
		created_date: time.utc()
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
		created_date: time.utc()
	}

	sql session_db {
		insert password_reset into PasswordReset
	}!
}

fn reset_password(reset &PasswordResetValues) ! {
	mut v := validation.start()
	v.validate(reset.token.len > 0, 'Token cannot be empty.')
	v.validate(reset.password.len > 0, 'Password cannot be empty.')
	v.validate(reset.password_confirm.len > 0, 'Password confirm cannot be empty.')
	v.validate(reset.password == reset.password_confirm, 'Passwords do not match.')
	v.result()!

	session_db := reset.session_db
	user_db := reset.user_db

	password_reset_ := sql session_db {
		select from PasswordReset where token == reset.token limit 1
	}!
	if password_reset_.len == 0 {
		return msg.validation_error('Token has expired.')
	}

	password_reset := password_reset_[0]
	// Check if token has expired
	duration := time.Duration(1000 * 1000 * 1000 * 60 * 30)
	if password_reset.created_date > time.utc().add(duration) {
		sql session_db {
			delete from PasswordReset where token == reset.token
		}!
		return msg.validation_error('Token has expired.')
	}

	user_id := password_reset.user_id

	salted_password := hash_password(reset.password, reset.salt)
	sql user_db {
		update User set password = salted_password where id == user_id
	}!

	sql session_db {
		delete from PasswordReset where token == reset.token
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
