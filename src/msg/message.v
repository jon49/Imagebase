module msg

const (
    success = SuccessMessage {msg: ''}
)

pub struct Message {
    msg string
}

pub fn (err Message) msg() string {
    return err.msg
}

pub fn (err Message) code() int {
    return 0
}

pub struct SuccessMessage {
    Message
}

pub struct ValidationMessage {
    Message
}

pub struct UnauthorizedMessage {
    Message
}

pub struct NotFoundMessage {
    Message
}

pub struct BadRequestMessage {
    Message
}

pub fn unauthorized() IError {
    return &UnauthorizedMessage{ msg: 'You are unauthorized to access this page.' }
}

pub fn not_found(message string) IError {
    return &NotFoundMessage{ msg: message }
}

pub fn validation_error(message string) IError {
    return &ValidationMessage{ msg: message }
}

pub fn bad_request(message string) IError {
    return &BadRequestMessage{ msg: message }
}

pub fn success() IError {
    return &success
}

