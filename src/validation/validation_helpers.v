module validation

import msg

pub fn assert_found(value int, name string) ! {
	if value < 1 {
		return msg.not_found('Could not find "${name}".')
	}
}

pub fn validate(b bool, message string) ! {
	if !b {
		return msg.validation_error(message)
	}
}

pub fn has_content(length int) ! {
	if length == 0 {
		return msg.success()
	}
}
