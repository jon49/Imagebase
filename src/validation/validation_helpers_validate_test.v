module validation

import msg

fn test_validate_success() {
	validate(true, 'It worked!') or { assert false, 'This should always succeed!' }
}

fn test_validate_fail() {
	validate(false, 'It failed — just like it should have!') or {
		match err {
			msg.ValidationMessage {
				assert err.msg() == 'It failed — just like it should have!'
				return
			}
			else {
				assert false, 'Should be ValidationMessage'
			}
		}
	}

	assert false, 'This should have exited early!'
}
