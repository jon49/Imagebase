module main

import time
import veb

struct UserDto {
	email    string @[required]
	password string @[required]
}

fn (mut ctx Context) set_session(session string) {
	expires := if session == '' {
		time.utc()
	} else {
		time.utc().add_days(30)
	}
	ctx.set_cookie(
		name:      'session'
		value:     if session == '' { 'logged_out' } else { session }
		expires:   expires
		secure:    true
		http_only: true
		same_site: .same_site_strict_mode
		path:      '/'
	)
}

@['/api/authentication/login'; post]
fn (mut app App) api_login_post(mut ctx Context) veb.Result {
	user := UserDto{
		email:    ctx.form['email']
		password: ctx.form['password']
	}

	session := app.login(user.email, user.password) or { return ctx.message_response(err) }

	ctx.set_session(session.session)

	return ctx.json('{"success":true}')
}

@['/api/authentication/logout'; post]
fn (mut app App) api_logout_post(mut ctx Context) veb.Result {
	app.delete_session(mut ctx) or { return ctx.message_response(err) }

	ctx.set_session('')
	ctx.res.set_status(.no_content)
	return ctx.ok('')
}

@['/api/authentication/reset-password'; post]
fn (mut app App) api_reset_password_post(mut ctx Context) veb.Result {
	token := ctx.form['token']
	password := ctx.form['password']
	password_confirm := ctx.form['passwordConfirm']

	session := app.reset_password(token, password, password_confirm) or {
		return ctx.message_response(err)
	}

	ctx.set_session(session.session)

	ctx.res.set_status(.no_content)
	return ctx.ok('')
}

@['/api/authentication/forgot-password'; post]
fn (mut app App) api_forgot_password_post(mut ctx Context) veb.Result {
	email := ctx.form['email']

	forgot_password(&app.user_db, &app.session_db, email) or { return ctx.message_response(err) }

	ctx.res.set_status(.no_content)
	return ctx.ok('')
}

@['/api/authentication/register'; post]
fn (mut app App) api_register(mut ctx Context) veb.Result {
	user := User{
		email:    ctx.form['email']
		password: ctx.form['password']
	}

	session := app.register(user.email, user.password) or { return ctx.message_response(err) }

	ctx.set_session(session)

	return ctx.json('{"success":true}')
}
