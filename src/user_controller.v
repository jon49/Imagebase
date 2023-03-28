module main

import time
import vweb

struct UserDto {
    email string [required]
    password string [required]
}

['/login'; get]
fn (mut app App) page_login() vweb.Result {
    error := app.query['error']
    return $vweb.html()
}

fn (mut app App) set_session(session string) {
    app.set_cookie(
        name: 'session',
        value: session,
        expires: time.utc().add_days(30),
        secure: true,
        http_only: true,
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
        error_message := 'Email or password is incorrect.'
        return app.redirect('/login?error=${error_message}')
    }

    app.set_session(session.session)

    return app.redirect('/web')
}

['/register'; get]
fn (mut app App) page_register() vweb.Result {
    error := app.query['error']
    return $vweb.html()
}

['/register'; post]
fn (mut app App) register_post() vweb.Result {
    user := User{
        email: app.form['user']
        password: app.form['password']
    }

    session := app.register(user.email, user.password) or {
        return app.redirect('/register?error=User not found.')
    }

    app.set_session(session)

    return app.redirect('/web')
}

