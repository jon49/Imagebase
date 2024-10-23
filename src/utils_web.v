module main

import net.http
import msg
import veb

struct ErrorResponse {
	status  int
	message string
}

fn (mut ctx Context) set_status_with_message(code int, error IError) &ErrorResponse {
	ctx.res.set_status(http.status_from_int(code))
	if code == 500 {
		return &ErrorResponse{500, 'Something happened which should not have.'}
	}
	return &ErrorResponse{code, error.msg()}
}

fn (mut ctx Context) message_response(e IError) veb.Result {
	return match e {
		msg.UnauthorizedMessage {
			message := ctx.set_status_with_message(401, e)
			ctx.json(message)
		}
		msg.NotFoundMessage {
			message := ctx.set_status_with_message(404, e)
			ctx.json(message)
		}
		msg.BadRequestMessage {
			message := ctx.set_status_with_message(400, e)
			ctx.json(message)
		}
		msg.ValidationMessage {
			message := ctx.set_status_with_message(400, e)
			ctx.json(message)
		}
		msg.SuccessMessage {
			ctx.res.set_status(.no_content)
			ctx.ok('')
		}
		else {
			ctx.res.set_status(.internal_server_error)
			message := ErrorResponse{500, 'Something happened which should not have.'}
			ctx.json(message)
		}
	}
}

fn (mut ctx Context) created(location string) {
	ctx.res.set_status(.created)
	ctx.res.header.add(.content_location, location)
}
