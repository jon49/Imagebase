// See: https://github.com/vlang/v/blob/master/vlib/vweb/tests/controller_test.v

module main

import db.sqlite
import net.http
import os
import time

const vexe = @VEXE
const test_path = os.join_path(os.temp_dir(), 'simple-server-test')
const config_filename = os.join_path(test_path, 'config.json')
const temp_filename = os.join_path(test_path, 'temp.txt')
const app_path = os.join_path(test_path, 'my-app')
const static_files = os.join_path(app_path, 'static')
const static_file = os.join_path(static_files, 'index.html')
const sport = 12382
const local_url = 'http://localhost:${sport}'
const serverexe = os.join_path(os.cache_dir(), 'SimpleServer.exe')
const cwd = os.getwd()
const cmd_suffix = '> /dev/null &'
const kill_key = 'killme'

struct Test {
mut:
	session string
}

fn testsuite_begin() {
	os.mkdir(test_path) or {}
	mut f := os.create(config_filename)!
	f.write_string('{
    "appPath":"${app_path}",
    "port": ${sport},
    "staticFiles": "${static_files}",
    "killKey": "${kill_key}"
}')!
	f.close()

	os.mkdir_all(static_files)!
	mut f2 := os.create(static_file)!
	f2.write_string('hello world')!
	f2.close()

	if os.exists(serverexe) {
		os.rm(serverexe) or {}
	}
}

fn testsuite_end() {
}

fn test_created_executable() {
	did_server_compile := os.system('${os.quoted_path(vexe)} -o ${os.quoted_path(serverexe)} .')
	assert did_server_compile == 0
	assert os.exists(serverexe)
}

fn test_starts_server() {
	command := '${os.quoted_path(serverexe)} --config ${os.quoted_path(config_filename)} > /dev/null &'
	res := os.system(command)
	assert res == 0
	time.sleep(100 * time.millisecond)
}

fn test_databases_created() {
	assert os.exists(os.join_path(app_path, 'data.db'))
	assert os.exists(os.join_path(app_path, 'sessions.db'))
	assert os.exists(os.join_path(app_path, 'users.db'))
}

fn test_can_get_static_file() {
	x := http.fetch(url: '${local_url}/index.html') or {
		assert err.msg() == ''
		return
	}
	assert x.status() == .ok
	assert x.body == 'hello world'
}

fn test_should_fail_when_not_logged_in_and_adding_data() {
	response := http.post_json('${local_url}/api/data', '{}') or {
		assert err.msg() == ''
		return
	}
	assert response.body == 'Unauthorized'
	assert response.status() == .unauthorized
}

fn test_should_reject_invalid_submissions() {
	response := http.post_form('${local_url}/api/authentication/register', {
		'email':    ''
		'password': 'password'
	})!
	assert response.status() == .bad_request

	response2 := http.post_form('${local_url}/api/authentication/register', {
		'email':    'test@test.com'
		'password': ''
	})!
	assert response2.status() == .bad_request
}

fn test_should_be_able_to_register_new_user() {
	response := http.post_form('${local_url}/api/authentication/register', {
		'email':    'test@test.com'
		'password': 'password'
	})!
	assert response.status() == .ok
	cookie := response.header.get(.set_cookie)!
	session := cookie.split(';')[0].split('=')[1]
	assert session.len > 0
}

fn test_should_reject_invalid_login() {
	response := http.post_form('${local_url}/api/authentication/login', {
		'email':    ''
		'password': 'password'
	})!
	assert response.status() == .bad_request

	response2 := http.post_form('${local_url}/api/authentication/login', {
		'email':    'test@test.com'
		'password': ''
	})!
	assert response2.status() == .bad_request
}

fn test_should_be_able_to_login() {
	fail_password := http.post_form('${local_url}/api/authentication/login', {
		'email':    'test@test.com'
		'password': 'a'
	})!
	assert fail_password.status() == .bad_request

	fail_email := http.post_form('${local_url}/api/authentication/login', {
		'email':    'test1@test.com'
		'password': 'password'
	})!
	assert fail_email.status() == .bad_request

	session := login()!
	assert session.len > 0
}

fn test_should_be_able_to_add_data() {
	session := login()!

	response := http.fetch(http.FetchConfig{
		url:     '${local_url}/api/data'
		method:  .post
		cookies: {
			'session': session
		}
		data:    '{ "lastSyncId": 0,
           "data": [{
               "key": [1, "test-key"],
               "data": { "my": "data", "is": "here" },
               "id": 0 }, {
               "key": "test-key2",
               "data": { "my": "data2", "is": "here2" },
               "id": 0 }
           ] }'
	})!

	assert response.status() == .ok
	assert response.body == '{"data":[],"saved":[{"key":"[1,\\"test-key\\"]","id":1},{"key":"\\"test-key2\\"","id":2}],"conflicted":[],"lastSyncedId":2}'

	response2 := http.fetch(http.FetchConfig{
		url:     '${local_url}/api/data'
		method:  .post
		cookies: {
			'session': session
		}
		data:    '{ "lastSyncedId": 1,
           "data": [{
               "key": "test-key2",
               "data": { "my": "data", "is": "here" },
               "id": 0 }
           ] }'
	})!

	assert response2.status() == .ok
	assert response2.body.starts_with('{"data":[],"saved":[{"key":"\\"test-key2\\"","id":3}],"conflicted":[{"key":"\\"test-key2\\"","data":"{\\"my\\":\\"data2\\",\\"is\\":\\"here2\\"}","id":2,"t')
	assert response2.body.ends_with('"}],"lastSyncedId":3}')

	response3 := http.fetch(http.FetchConfig{
		url:     '${local_url}/api/data'
		method:  .post
		cookies: {
			'session': session
		}
		data:    '{ "lastSyncedId": 0 }'
	})!

	assert response3.status() == .ok
	assert response3.body == '{"data":[{"key":"[1,\\"test-key\\"]","data":"{\\"my\\":\\"data\\",\\"is\\":\\"here\\"}","id":1},{"key":"\\"test-key2\\"","data":"{\\"my\\":\\"data\\",\\"is\\":\\"here\\"}","id":3}],"saved":[],"conflicted":[],"lastSyncedId":3}'
}

fn test_should_be_able_to_logout() {
	session := login()!

	response := http.fetch(http.FetchConfig{
		url:     '${local_url}/api/authentication/logout'
		method:  .post
		cookies: {
			'session': session
		}
	})!

	assert response.status() == .no_content

	response2 := http.fetch(http.FetchConfig{
		url:     '${local_url}/api/data'
		method:  .post
		cookies: {
			'session': session
		}
	})!

	assert response2.status() == .unauthorized
}

fn test_should_be_able_to_create_forgot_password_token() {
	session := login()!

	response := http.post_form('${local_url}/api/authentication/forgot-password', {
		'email': 'test@test.com'
	})!

	assert response.status() == .no_content

	session_db_path := os.join_path(app_path, 'sessions.db')
	mut session_db := sqlite.connect(session_db_path)!

	resets := sql session_db {
		select from PasswordReset
	}!

	assert resets.len == 1
}

fn test_should_be_able_to_create_new_password() {
	session_db_path := os.join_path(app_path, 'sessions.db')
	mut session_db := sqlite.connect(session_db_path)!
	resets := sql session_db {
		select from PasswordReset
	}!

	user_db_path := os.join_path(app_path, 'users.db')
	mut user_db := sqlite.connect(user_db_path)!
	users := sql user_db {
		select from User
	}!
	old_password := users[0].password

	response := http.post_form('${local_url}/api/authentication/reset-password', {
		'token':           resets[0].token
		'password':        'new password'
		'passwordConfirm': 'new password'
	})!

	assert response.status() == .no_content, response.body

	response2 := http.post_form('${local_url}/api/authentication/login', {
		'email':    'test@test.com'
		'password': 'new password'
	})!

	assert response2.status() == .ok

	users_2 := sql user_db {
		select from User
	}!
	new_password := users_2[0].password

	assert old_password != new_password

	password_reset_count := sql session_db {
		select count from PasswordReset
	}!

	assert password_reset_count == 0
}

fn test_shutdown() {
	x := http.fetch(
		url:    '${local_url}/shutdown?key=${kill_key}'
		method: .post
	) or {
		assert err.msg() == ''
		return
	}
	assert x.status() == .ok
	assert x.body == 'good bye'
	os.rmdir_all(test_path)!
}

fn login() !string {
	response := http.post_form('${local_url}/api/authentication/login', {
		'email':    'test@test.com'
		'password': 'password'
	})!
	assert response.status() == .ok
	cookie := response.header.get(.set_cookie)!
	session := cookie.split(';')[0].split('=')[1]
	return session
}
