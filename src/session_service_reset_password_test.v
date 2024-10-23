module main

import db.sqlite
import msg
import time

fn test_should_return_validation_error_for_empty_token() {
	mut app := create_app()!
	app.reset_password('', 'new_password', 'new_password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Token cannot be empty.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		return
	}
	assert false, 'Should return early.'
}

fn test_should_return_validation_error_for_empty_password() {
	mut app := create_app()!
	app.reset_password('my token', '', 'new_password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Password cannot be empty.\nPasswords do not match.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		return
	}
	assert false, 'Should return early.'
}

fn test_should_return_validation_error_for_non_matching_passwords() {
	mut app := create_app()!
	app.reset_password('my token', 'password', 'new_password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Passwords do not match.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		return
	}
	assert false, 'Should return early.'
}

fn test_should_return_validation_error_when_no_token_found() {
	mut app := create_app()!
	app.reset_password('token', 'new_password', 'new_password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Token has expired.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		return
	}
	assert false, 'Should return early.'
}

fn test_should_return_validation_error_when_token_is_expired() {
	mut app := create_app()!

	reset := PasswordReset{
		user_id:      1
		token:        'token'
		created_date: time.utc().add(time.Duration(1000 * 1000 * 1000 * 60 * 60))
	}

	sql app.session_db {
		insert reset into PasswordReset
	}!

	app.reset_password('token', 'password', 'password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Token has expired.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		count := sql app.session_db {
			select count from PasswordReset
		}!
		assert count == 0, 'Should delete the token.'
		return
	}
	assert false, 'Should return early.'
}

fn create_app() !App {
	mut user_db := sqlite.connect(':memory:')!
	sql user_db {
		create table User
	}!
	mut session_db := sqlite.connect(':memory:')!
	create_session_db(&session_db)!
	return App{
		user_db:    user_db
		session_db: session_db
		salt:       'salt'
	}
}
