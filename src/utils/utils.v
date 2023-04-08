module utils

import json
import msg

pub fn parse_json[T](data string) !T {
	value := json.decode(T, data) or {
        return msg.bad_request('Invalid JSON Payload')
    }
    return value
}

