module main

import db.sqlite
import note { Note }
import vweb

pub struct App {
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

pub fn (mut app App) before_request() {
    session := app.get_cookie('session') or { '' }
    if session.len > 0 {
        session_record := sql app.session_db {
            select from Session where session == session limit 1
        }
        app.user_id = session_record.user_id
        app.session = session
    }

    /* if app.user_id < 1 { */
    /*     app.redirect('/login') */
    /* } */
}

fn main() {
	db := sqlite.connect('notes.db')!
	sql db {
		create table Note
	}

    session_db := sqlite.connect('sessions.db')!
    sql session_db {
        create table Session
    }

    user_db := sqlite.connect('users.db')!
    sql user_db {
        create table User
    }

	http_port := 8000

	app := &App{
		db: db
        session_db: session_db
        user_db: user_db
	}

	vweb.run(app, http_port)
}

