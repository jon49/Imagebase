module main

pub fn (mut app App) check_auth(mut ctx Context) bool {
	session := ctx.get_cookie('session') or { '' }
	if session.len > 0 {
		session_record := sql app.session_db {
			select from Session where session == session limit 1
		} or { [] }
		if session_record.len > 0 {
			ctx.user_id = session_record[0].user_id
			ctx.session = session
			return true
		}
	}
	ctx.res.set_status(.unauthorized)
	ctx.ok('Unauthorized')
	return false
}
