import os

const (
    vexe = @VEXE
    test_path = os.join_path(os.temp_dir(), 'simple-server-test')
    config_filename = os.join_path(test_path, 'config.json')
    app_path = os.join_path(test_path, 'my-app')
    static_files = os.join_path(app_path, 'static')
    sport = 12382
    local_server = 'http://localhost:${sport}'
    serverexe = os.join_path(os.cache_dir(), 'SimpleServer.exe')
    cwd = os.getwd()
)

fn testsuite_begin() {
    os.mkdir(test_path) or {}
    mut f := os.create(config_filename)!
    f.write_string('{
    "appPath":"${app_path}",
    "port": ${sport},
    "staticFiles": "${static_files}"
}')!
    f.close()

    if os.exists(serverexe) {
        os.rm(serverexe) or {}
    }
}

fn testsuite_end() {
}

fn test_created_executable() {
    result := os.system('${os.quoted_path(vexe)} -o ${os.quoted_path(serverexe)} .')
    assert result == 0
    assert os.exists(serverexe)
}

// Start server
// test static file
// add data → Make sure I'm not allowed to.
// register
// login
// add data
// stop server

