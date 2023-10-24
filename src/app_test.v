// See: https://github.com/vlang/v/blob/master/vlib/vweb/tests/controller_test.v
import net.http
import os
import time

const (
	vexe            = @VEXE
	test_path       = os.join_path(os.temp_dir(), 'simple-server-test')
	config_filename = os.join_path(test_path, 'config.json')
	temp_filename   = os.join_path(test_path, 'temp.txt')
	app_path        = os.join_path(test_path, 'my-app')
	static_files    = os.join_path(app_path, 'static')
	static_file     = os.join_path(static_files, 'index.html')
	sport           = 12382
	local_url       = 'http://localhost:${sport}'
	serverexe       = os.join_path(os.cache_dir(), 'SimpleServer.exe')
	cwd             = os.getwd()
	cmd_suffix      = '> /dev/null &'
	kill_key        = 'killme'
)

struct Test {
mut:
	session string
}

pub struct DataDto {
pub:
	key  string
	data ?string
	id   int
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
	response := http.post_form('${local_url}/api/register', {
		'email':    ''
		'password': 'password'
	})!
	assert response.status() == .bad_request

	response2 := http.post_form('${local_url}/api/register', {
		'email':    'test@test.com'
		'password': ''
	})!
	assert response2.status() == .bad_request
}

fn test_should_be_able_to_register_new_user() {
	response := http.post_form('${local_url}/api/register', {
		'email':    'test@test.com'
		'password': 'password'
	})!
	assert response.status() == .ok
	cookie := response.header.get(.set_cookie)!
	session := cookie.split(';')[0].split('=')[1]
	assert session.len > 0
}

fn test_should_reject_invalid_login() {
	response := http.post_form('${local_url}/api/login', {
		'email':    ''
		'password': 'password'
	})!
	assert response.status() == .bad_request

	response2 := http.post_form('${local_url}/api/login', {
		'email':    'test@test.com'
		'password': ''
	})!
	assert response2.status() == .bad_request
}

fn test_should_be_able_to_login() {
	fail_password := http.post_form('${local_url}/api/login', {
		'email':    'test@test.com'
		'password': 'a'
	})!
	assert fail_password.status() == .bad_request

	fail_email := http.post_form('${local_url}/api/login', {
		'email':    'test1@test.com'
		'password': 'password'
	})!
	assert fail_email.status() == .bad_request

	session := login()!
	assert session.len > 0
}

fn login() !string {
	response := http.post_form('${local_url}/api/login', {
		'email':    'test@test.com'
		'password': 'password'
	})!
	assert response.status() == .ok
	cookie := response.header.get(.set_cookie)!
	session := cookie.split(';')[0].split('=')[1]
	return session
}

fn test_should_be_able_to_logout() {
	session := login()!

	response := http.fetch(http.FetchConfig{
		url: '${local_url}/api/logout'
		method: .post
		cookies: {
			'session': session
		}
	})!

	assert response.status() == .no_content

	response2 := http.fetch(http.FetchConfig{
		url: '${local_url}/api/data'
		method: .post
		cookies: {
			'session': session
		}
	})!

	assert response2.status() == .unauthorized
}

fn test_should_be_able_to_add_data() {
	session := login()!

	response := http.fetch(http.FetchConfig{
		url: '${local_url}/api/data'
		method: .post
		cookies: {
			'session': session
		}
		data: '{ "lastSyncId": 0,
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
		url: '${local_url}/api/data'
		method: .post
		cookies: {
			'session': session
		}
		data: '{ "lastSyncedId": 1,
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
		url: '${local_url}/api/data'
		method: .post
		cookies: {
			'session': session
		}
		data: '{ "lastSyncedId": 0 }'
	})!

	assert response3.status() == .ok
	assert response3.body == '{"data":[{"key":"[1,\\"test-key\\"]","data":"{\\"my\\":\\"data\\",\\"is\\":\\"here\\"}","id":1},{"key":"\\"test-key2\\"","data":"{\\"my\\":\\"data\\",\\"is\\":\\"here\\"}","id":3}],"saved":[],"conflicted":[],"lastSyncedId":3}'
}

fn test_shutdown() {
	x := http.fetch(
		url: '${local_url}/shutdown?key=${kill_key}'
		method: .post
	) or {
		assert err.msg() == ''
		return
	}
	assert x.status() == .ok
	assert x.body == 'good bye'
	os.rmdir_all(test_path)!
}
