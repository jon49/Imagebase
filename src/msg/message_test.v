module msg

fn test_unauthorized() {
	val := unauthorized()
	match val {
		UnauthorizedMessage {
			assert val.msg() == 'You are unauthorized to access this page.'
		}
		else {
			assert false
		}
	}
}

fn test_not_found() {
	message := 'Yep, I really could not find it!'
	val := not_found(message)
	match val {
		NotFoundMessage {
			assert val.msg() == message
		}
		else {
			assert false
		}
	}
}

fn test_validation_error() {
	message := 'Validation ERROR!!!'
	val := validation_error(message)
	match val {
		ValidationMessage {
			assert val.msg() == message
		}
		else {
			assert false
		}
	}
}

fn test_bad_request() {
	message := 'BAD REQUEST!!!'
	val := bad_request(message)
	match val {
		BadRequestMessage {
			assert val.msg() == message
		}
		else {
			assert false
		}
	}
}

fn test_success() {
	val := success()
	match val {
		SuccessMessage {
			assert val.msg() == ''
		}
		else {
			assert false
		}
	}
}
