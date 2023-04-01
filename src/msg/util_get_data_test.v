module msg

struct Test {
    age int
    name string
}

fn test_get_data_success() {
    val := get_data[Test]('{"age":25,"name":"George"}') or {
        assert false
        return
    }
    assert val.age == 25
    assert val.name == 'George'
}

fn test_get_data_fail() {
    val := get_data[Test]('{"age":25"name":"George"}') or {
        match err {
            BadRequestMessage {
                assert err.msg() == 'Invalid JSON Payload'
            }
            else {
                assert false, 'Should be a `BadRequestMessage` message.'
            }
        }
        return
    }
    assert false, 'JSON parsing should have failed.'
}

