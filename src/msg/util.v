module msg

import json

pub fn get_data[T](data string) !T {
	value := json.decode(T, data) or {
        return msg.bad_request('Invalid JSON Payload')
    }
    return value
}

