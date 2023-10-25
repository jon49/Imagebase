module main

import db.sqlite
import msg

fn test_when_empty_password_return_early() {
	mut user_db := sqlite.connect(':memory:')!
	mut session_db := sqlite.connect(':memory:')!
	forgot_password(&user_db, &session_db, '') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'Email cannot be empty.'
			}
			else {
				assert false, 'Should be a `ValidationMessage` message.'
			}
		}
		return
	}
	assert false, 'Should return early.'
}

fn test_no_reset_token_created_when_no_matching_user() {
	mut user_db := sqlite.connect(':memory:')!
	sql user_db {
		create table User
	}!
	mut session_db := sqlite.connect(':memory:')!
	create_session_db(&session_db)!
	forgot_password(&user_db, &session_db, 'a@b.c')!
	assert sql session_db {
		select count from PasswordReset
	}! == 0
}

// This is tested at the API level.
fn test_should_be_able_to_create_a_token_to_reset_password() {
}
