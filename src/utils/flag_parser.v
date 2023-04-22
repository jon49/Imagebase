module utils

import flag
import json
import os

pub struct Config {
pub:
    app_path string          [json: appPath]
    port int = 8000
    static_files_path string [json: staticFiles]
    kill_key string [json: killKey]
}

pub fn get_config(args []string) !&Config {
    mut fp := flag.new_flag_parser(args)
    path := fp.string('config', `c`, '', 'Path to the config file.')
    fp.finalize()!
    if path.len > 0 {
        return get_config_from_file(path)!
    }
    return &Config{}
}

fn get_config_from_file(path string) !&Config {
    contents := os.read_file(path)!
    if contents.len > 0 {
        config := json.decode(Config, contents)!
        return &config
    }
    return error('No content in config file! File location "${path}".')
}

