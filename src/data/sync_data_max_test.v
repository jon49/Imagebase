module data

fn test_max() {
    arr := [3, 5, 1, 2 ].map(i64(it))
    high := max(arr)
    assert high == 5
}

