module validation

import msg

fn test_assert_found_success() {
    assert_found(1, 'id') or {
        assert false
        return
    }
}

fn test_assert_found_fail() {
    for i in 0..1 {
        assert_found(i - 1, 'id') or {
            match err {
                msg.NotFoundMessage {
                    assert err.msg() == 'Could not find "id".'
                }
                else { assert false, 'Should be a NotFoundMessage.' }
            }
        }
        return
    }

    assert false, 'Should have failed.'
}

