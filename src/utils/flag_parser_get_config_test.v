module utils

import os

const (
    file_name = 'test.json'
    empty_file = 'empty.json'
)

fn testsuite_begin() {
    mut f := os.create(file_name)!
    f.write_string('{"appPath":"${file_name}","port":8888}')!
    f.close()
    mut empty := os.create(empty_file)!
    f.close()
}

fn test_get_config_without_path() {
    result := get_config(['path/to/binary']) or { panic(err) }
    assert result == Config{
        app_path: ''
        port: 8000
    }
}

fn test_get_config_with_file() {
    result := get_config(['path/to/binary', '--config=${file_name}']) or { panic(err) }
    assert result == Config{
        app_path: file_name
        port: 8888
    }
}

fn test_get_config_with_empty_file() {
    result := get_config(['path/to/binary', '--config=${empty_file}']) or {
        assert err.msg() == 'No content in config file! File location "empty.json".'
        return
    }
    assert false, 'Should never return data.'
}

fn testsuite_end() {
    os.rm(file_name)!
    os.rm(empty_file)!
}

