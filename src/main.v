module main

import data
import db.sqlite
import notes { Note }
import os
import utils { get_config }
import vweb

struct App {
	vweb.Context
pub:
    salt string = 'yellow'
pub mut:
	db sqlite.DB
    session_db sqlite.DB
    user_db sqlite.DB
    data_db sqlite.DB
    user_id int
    session string
}

fn main() {
    config := get_config(os.args)!

	mut app := &App{}
    /*     middlewares: { */
    /*         '/api/': [authentication_middleware] */
    /*         '/notes/': [authentication_middleware] */
    /*     } */
    /* } */

    app.set_up_databases(config.app_path)!

	vweb.run(app, config.port)
}

fn get_db_path(app_path string, db_name string) string {
    return if app_path.len > 0 {
        os.join_path(app_path, db_name)
    } else { ':memory:' }
}

fn (mut app App) set_up_databases(app_path string) ! {
    notes_path := get_db_path(app_path, 'notes.db')
	mut notes_db := sqlite.connect(notes_path)!
	sql notes_db { create table Note } or { panic(err) }

    sessions_path := get_db_path(app_path, 'sessions.db')
    mut session_db := sqlite.connect(sessions_path)!
    sql session_db { create table Session } or { panic(err) }

    users_path := get_db_path(app_path, 'users.db')
    mut user_db := sqlite.connect(users_path)!
    sql user_db { create table User } or { panic(err) }

    data_path := get_db_path(app_path, 'data.db')
    mut data_db := sqlite.connect(data_path)!
    data.create_db(&data_db)!

    app.db = notes_db
    app.session_db = session_db
    app.user_db = user_db
    app.data_db = data_db
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
        } or { panic(err) }
        if session.len > 0 {
            app.user_id = session_record[0].user_id
            app.session = session
        }
    }
    /* if app.user_id < 1 { */
    /*     app.redirect('/login') */
    /* } */
}

