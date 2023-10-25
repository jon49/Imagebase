module main

import db.sqlite
import msg
import time

fn test_should_return_validation_error_for_empty_token() {
	mut user_db := sqlite.connect(':memory:')!
	mut session_db := sqlite.connect(':memory:')!
	reset_password(&user_db, &session_db, 'salt', '', 'new_password') or {
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
	mut user_db := sqlite.connect(':memory:')!
	mut session_db := sqlite.connect(':memory:')!
	reset_password(&user_db, &session_db, 'salt', 'my token', '') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Password cannot be empty.'
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
	dbs := create_dbs()!
	user_db := dbs[0]
	session_db := dbs[1]

	reset_password(user_db, session_db, 'salt', 'token', 'password') or {
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
	dbs := create_dbs()!
	user_db := dbs[0]
	session_db := dbs[1]

	reset := PasswordReset{
		user_id: 1
		token: 'token'
		created_date: time.utc().add(time.Duration(1000 * 1000 * 1000 * 60 * 60))
	}

	sql session_db {
		insert reset into PasswordReset
	}!

	reset_password(user_db, session_db, 'salt', 'token', 'password') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Token has expired.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		count := sql session_db {
			select count from PasswordReset
		}!
		assert count == 0, 'Should delete the token.'
		return
	}
	assert false, 'Should return early.'
}

fn create_dbs() ![]&sqlite.DB {
	mut user_db := sqlite.connect(':memory:')!
	sql user_db {
		create table User
	}!
	mut session_db := sqlite.connect(':memory:')!
	create_session_db(&session_db)!
	return [&user_db, &session_db]
}
