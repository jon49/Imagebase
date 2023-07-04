// See: https://github.com/vlang/v/blob/master/vlib/vweb/tests/controller_test.v

import net.http
import os
import time

const (
    vexe = @VEXE
    test_path = os.join_path(os.temp_dir(), 'simple-server-test')
    config_filename = os.join_path(test_path, 'config.json')
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

    os.mkdir(static_files) or {}
    f = os.create(static_file)!
    f.write_string('hello world')!
    f.close()

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
    println(command)
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

// add data → Make sure I'm not allowed to.
// register
// login
// add data
// stop server

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
}

