// Repro for a Goose v2026.4 code-generation bug (goose build and goose run),
// reported as https://github.com/aardappel/goose/issues/431.
//
// A function whose `defer` sits in its outermost block, that returns a bool,
// and that is inlined into an `if` or `while` condition skips the defer on
// the false path. Expected output: every line ends in "2" (the defer ran).
//
//     $ goose build docs/goose-defer-bug.goose && docs/goose-defer-bug
//     if f(false):  [1]          <- defer skipped
//     let a = f(false); if a: [1, 2]
//     if k(false):  [1, 2]       <- workaround: defer in an inner block
var log: i64[>..];
fn step() -> bool { log.push(1); true }
fn done() { log.push(2); }
fn f(x: bool) -> bool { defer done(); return step() && x; }
fn k(x: bool) -> bool { var r = false; { defer done(); r = step() && x; } return r; }
fn main() {
    if f(false) { print("taken"); }
    print("if f(false):  ", log); log.clear();
    let a = f(false); if a { print("taken"); }
    print("let a = f(false); if a: ", log); log.clear();
    if k(false) { print("taken"); }
    print("if k(false):  ", log); log.clear();
}
