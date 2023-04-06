module validation

fn test_validate() {
    mut v := start()
    v.validate(true, 'Should never be in array.')
    v.validate(false, 'Error message.')
    result := v.errors()

    assert result == ['Error message.']
}

fn test_validate_join() {
    mut v := start()
    v.validate(false, 'Error1')
    v.validate(false, 'Error2')
    result := v.join("|")

    assert result == 'Error1|Error2'
}

fn test_validate_assert() {
    mut v := start()
    v.validate(false, 'Error1')
    v.validate(false, 'Error2')
    mut result := ''
    v.result() or {
        result = err.msg()
    }

    assert result == 'Error1\nError2'
}

