module validation

import msg

struct Validation {
mut:
	errors []string
}

pub fn start() &Validation {
	mut v := &Validation{}
	return v
}

pub fn (mut v Validation) validate(b bool, message string) {
	if !b {
		v.errors << message
	}
}

pub fn (v &Validation) errors() []string {
	return v.errors
}

pub fn (v &Validation) join(delimiter string) string {
	return v.errors.join(delimiter)
}

pub fn (v &Validation) result() ! {
	if v.errors.len > 0 {
		return msg.validation_error(v.join('\n'))
	}
}
