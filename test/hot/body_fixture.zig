// Simple functions for body compiler smoke testing.
// Used by hot-smoke-test.sh to verify compile-body nREPL op.

fn answer() i64 {
    return 42;
}

fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn sumToTen() i64 {
    var i: i64 = 0;
    var total: i64 = 0;
    while (i < 10) {
        i += 1;
        total += i;
    }
    return total;
}

fn double(x: i64) i64 {
    return x * 2;
}

fn doubleAnswer() i64 {
    return double(answer());
}
