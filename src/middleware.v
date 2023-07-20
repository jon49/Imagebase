module main

pub fn (mut app App) check_auth() bool {
    session := app.get_cookie('session') or { '' }
    if session.len > 0 {
        session_record := sql app.session_db {
            select from Session where session == session limit 1
        } or { panic(err) }
        if session.len > 0 {
            app.user_id = session_record[0].user_id
            app.session = session
            return true
        }
    }
    app.set_status(401, '')
    app.text('Unauthorized')
    return false
}

