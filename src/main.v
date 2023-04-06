module main

import db.sqlite
import notes { Note }
import vweb

struct App {
	vweb.Context
pub:
    salt string = 'yellow'
pub mut:
	db sqlite.DB
    session_db sqlite.DB
    user_db sqlite.DB
    user_id int
    session string
}

fn main() {
	http_port := 8000

	mut app := &App{}
    /*     middlewares: { */
    /*         '/api/': [authentication_middleware] */
    /*         '/notes/': [authentication_middleware] */
    /*     } */
    /* } */

    app.set_up_databases()!

	vweb.run(app, http_port)
}

fn (mut app App) set_up_databases() ! {
	mut db := sqlite.connect('notes.db')!
	sql db {
		create table Note
	}

    mut session_db := sqlite.connect('sessions.db')!
    sql session_db {
        create table Session
    }

    mut user_db := sqlite.connect('users.db')!
    sql user_db {
        create table User
    }

    app.db = db
    app.session_db = session_db
    app.user_db = user_db
}

pub fn (mut app App) before_request() {
    if !(app.req.url.starts_with('/api')
        || app.req.url.starts_with('notes')) {
        return
    }
    session := app.get_cookie('session') or { '' }
    if session.len > 0 {
        session_record := sql app.session_db {
            select from Session where session == session limit 1
        }
        if session.len > 0 {
            app.user_id = session_record[0].user_id
            app.session = session
        }
    }
    /* if app.user_id < 1 { */
    /*     app.redirect('/login') */
    /* } */
}

