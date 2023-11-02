module main

import time
import vweb

struct UserDto {
	email    string [required]
	password string [required]
}

fn (mut app App) set_session(session string) {
	expires := if session == '' {
		time.utc()
	} else {
		time.utc().add_days(30)
	}
	app.set_cookie(
		name: 'session'
		value: if session == '' { 'logged_out' } else { session }
		expires: expires
		secure: true
		http_only: true
		same_site: .same_site_strict_mode
		path: '/'
	)
}

['/api/authentication/login'; post]
fn (mut app App) api_login_post() vweb.Result {
	user := UserDto{
		email: app.form['email']
		password: app.form['password']
	}

	session := app.login(user.email, user.password) or { return app.message_response(err) }

	app.set_session(session.session)

	return app.json('{"success":true}')
}

[middleware: check_auth]
['/api/authentication/logout'; post]
fn (mut app App) api_logout_post() vweb.Result {
	app.delete_session() or { return app.message_response(err) }

	app.set_session('')
	app.set_status(204, '')
	return app.ok('')
}

['/api/authentication/reset-password'; post]
fn (mut app App) api_reset_password_post() vweb.Result {
	token := app.form['token']
	password := app.form['password']
	password_confirm := app.form['passwordConfirm']

	app.reset_password(token, password, password_confirm) or { return app.message_response(err) }

	app.set_status(204, '')
	return app.ok('')
}

['/api/authentication/forgot-password'; post]
fn (mut app App) api_forgot_password_post() vweb.Result {
	email := app.form['email']

	forgot_password(&app.user_db, &app.session_db, email) or { return app.message_response(err) }

	app.set_status(204, '')
	return app.ok('')
}

['/api/authentication/register'; post]
fn (mut app App) api_register() vweb.Result {
	user := User{
		email: app.form['email']
		password: app.form['password']
	}

	session := app.register(user.email, user.password) or { return app.message_response(err) }

	app.set_session(session)

	return app.json('{"success":true}')
}
