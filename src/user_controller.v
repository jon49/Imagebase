module main

import time
import vweb

struct UserDto {
	email    string [required]
	password string [required]
}

['/login'; get]
fn (mut app App) page_login() vweb.Result {
	error := app.query['error']
	return $vweb.html()
}

fn (mut app App) set_session(session string) {
	app.set_cookie(
		name: 'session'
		value: session
		expires: time.utc().add_days(30)
		secure: true
		http_only: true
		same_site: .same_site_strict_mode
	)
}

['/login'; post]
fn (mut app App) login_post() vweb.Result {
	user := UserDto{
		email: app.form['email']
		password: app.form['password']
	}

	session := app.login(user.email, user.password) or {
		return app.redirect('/login?error=${err.msg()}')
	}

	app.set_session(session.session)

	return app.redirect('/web/?success=true')
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

['/register'; get]
fn (mut app App) page_register() vweb.Result {
	error := app.query['error']
	return $vweb.html()
}

['/register'; post]
fn (mut app App) register_post() vweb.Result {
	user := User{
		email: app.form['email']
		password: app.form['password']
	}

	session := app.register(user.email, user.password) or {
		return app.redirect('/register/?error=${err.msg()}.')
	}

	app.set_session(session)

	return app.redirect('/web/?success=true')
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
