module main

import data
import db.sqlite
import os
import time
import utils { get_config }
import veb

pub struct Context {
	veb.Context
pub mut:
	user_id int
	session string
}

pub struct App {
	veb.StaticHandler
	veb.Middleware[Context]
pub:
	kill_key string @[veb_global]
	salt     string @[veb_global]
pub mut:
	db         sqlite.DB
	session_db sqlite.DB @[veb_global]
	user_db    sqlite.DB @[veb_global]
}

fn main() {
	config := get_config(os.args)!

	mut app := &App{
		kill_key: config.kill_key
		salt:     config.salt
	}

	app.set_up_databases(config.app_path)!

	if config.static_files_path.len > 0 {
		app.handle_static(config.static_files_path, true)!
	}

	app.route_use('/api/authentication/logout', handler: app.check_auth)
	app.route_use('/api/data', handler: app.check_auth)

	veb.run[App, Context](mut app, config.port)
}

@['/shutdown'; post]
fn (mut app App) shutdown(mut ctx Context) veb.Result {
	if app.kill_key.len == 0 {
		return ctx.text('Cannot kill me!')
	}
	key := ctx.query['key']
	if key != app.kill_key {
		return ctx.text('Wrong key!')
	}
	spawn app.gracefull_exit()
	return ctx.ok('good bye')
}

fn (mut app App) gracefull_exit() {
	time.sleep(100 * time.millisecond)
	exit(0)
}

fn get_db_path(app_path string, db_name string) string {
	return if app_path.len > 0 { db_name } else { ':memory:' }
}

fn (mut app App) set_up_databases(app_path string) ! {
	pwd := os.getwd()
	if app_path.len > 0 {
		if !os.exists(app_path) {
			println('Creating app directory: ' + app_path)
			os.mkdir_all(app_path)!
		}
		os.chdir(app_path)!
	}

	sessions_path := get_db_path(app_path, 'sessions.db')
	mut session_db := sqlite.connect(sessions_path)!
	create_session_db(&session_db)!

	users_path := get_db_path(app_path, 'users.db')
	mut user_db := sqlite.connect(users_path)!
	sql user_db {
		create table User
	}!

	data_path := get_db_path(app_path, 'data.db')
	mut data_db := sqlite.connect(data_path)!
	data.create_db(&data_db)!

	app.db = data_db
	app.session_db = session_db
	app.user_db = user_db

	if app_path.len > 0 {
		os.chdir(pwd)!
	}
}
