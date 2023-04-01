module msg

fn test_has_content_success() {
    has_content(0) or {
        match err {
            SuccessMessage {
                assert err.msg() == ''
                return
            }
            else {
                assert false, 'It should be a SuccessMessage!'
            }
        }
    }

    assert false, 'Should never reach here!'
}

fn test_has_content_fail() {
    has_content(1) or {
        assert false, 'Should never reach here!'
    }
}

