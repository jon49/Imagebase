// See: https://github.com/vlang/v/blob/master/vlib/vweb/tests/controller_test.v

import net.http
import os
import time

const (
    vexe = @VEXE
    test_path = os.join_path(os.temp_dir(), 'simple-server-test')
    config_filename = os.join_path(test_path, 'config.json')
    temp_filename = os.join_path(test_path, 'temp.txt')
    app_path = os.join_path(test_path, 'my-app')
    static_files = os.join_path(app_path, 'static')
    static_file = os.join_path(static_files, 'index.html')
    sport = 12382
    local_url = 'http://localhost:${sport}'
    serverexe = os.join_path(os.cache_dir(), 'SimpleServer.exe')
    cwd = os.getwd()
    cmd_suffix = '> /dev/null &'
    kill_key = 'killme'
)

struct Test {
mut:
    session string
}

pub struct DataDto {
pub:
    key string
    data ?string
    id int
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
    response := http.post_json(
        '${local_url}/api/data',
        '{}'
    ) or {
        assert err.msg() == ''
        return
    }
    assert response.body == 'Unauthorized'
    assert response.status() == .unauthorized
}


fn test_should_be_able_to_register_new_user() {
    response := http.post_form(
        '${local_url}/api/register', {
            'email': 'test@test.com',
            'password': 'password'
        }
    )!
    assert response.status() == .ok
    cookie := response.header.get(.set_cookie)!
    session := cookie.split(';')[0].split('=')[1]
    assert session.len > 0
}

fn test_should_be_able_to_login() {
    fail_password := http.post_form(
        '${local_url}/api/login', {
            'email': 'test@test.com',
            'password': 'a'
        }
    )!
    assert fail_password.status() == .bad_request

    fail_email := http.post_form(
        '${local_url}/api/login', {
            'email': 'test1@test.com',
            'password': 'password'
        }
    )!
    assert fail_email.status() == .bad_request

    response := http.post_form(
        '${local_url}/api/login', {
            'email': 'test@test.com',
            'password': 'password'
        }
    )!
    assert response.status() == .ok
    cookie := response.header.get(.set_cookie)!
    session := cookie.split(';')[0].split('=')[1]
    eprintln('session: ${session}')
    assert session.len > 0
}

// add data

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

