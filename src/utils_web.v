module main

import msg
import vweb

struct ErrorResponse {
	status  int
	message string
}

fn (mut app App) set_status_with_message(code int, error IError) &ErrorResponse {
	app.set_status(code, '')
	if code == 500 {
		return &ErrorResponse{500, 'Something happened which should not have.'}
	}
	return &ErrorResponse{code, error.msg()}
}

fn (mut app App) message_response(e IError) vweb.Result {
	return match e {
		msg.UnauthorizedMessage {
			message := app.set_status_with_message(401, e)
			app.json(message)
		}
		msg.NotFoundMessage {
			message := app.set_status_with_message(404, e)
			app.json(message)
		}
		msg.BadRequestMessage {
			message := app.set_status_with_message(400, e)
			app.json(message)
		}
		msg.ValidationMessage {
			message := app.set_status_with_message(400, e)
			app.json(message)
		}
		msg.SuccessMessage {
			app.set_status(204, '')
			app.ok('')
		}
		else {
			app.set_status(500, 'Internal Server Error')
			message := ErrorResponse{500, 'Something happened which should not have.'}
			app.json(message)
		}
	}
}

fn (mut app App) created(location string) {
	app.set_status(201, 'created')
	app.add_header('Content-Location', location)
}
