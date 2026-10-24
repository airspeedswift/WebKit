var string = '['.repeat(1000000) + ']'.repeat(1000000);
JSON.parse(string);

// Every nesting depth up to 40, and the depths on both sides of each multiple of 64 up to 256, of arrays,
// objects and both, through JSON.parse with and without a reviver, and through eval, at both string widths.

function shouldBe(actual, expected, what) {
    if (actual !== expected)
        throw new Error(what + ": expected " + expected + " but got " + actual);
}

function nest(depth, kind) {
    let open = "", close = "";
    for (let i = 0; i < depth; ++i) {
        let isObject = kind === "object" || (kind === "mixed" && i % 2);
        open += isObject ? "{\"k\":" : "[";
        close = (isObject ? "}" : "]") + close;
    }
    return open + "1" + close;
}

let depths = [];
for (let depth = 1; depth <= 40; ++depth)
    depths.push(depth);
for (let multiple = 64; multiple <= 256; multiple += 64)
    depths.push(multiple - 2, multiple - 1, multiple, multiple + 1, multiple + 2);

for (let depth of depths) {
    for (let kind of ["array", "object", "mixed"]) {
        let text = nest(depth, kind);
        let wide = ("\u0100" + text).substring(1);
        for (let source of [text, wide]) {
            shouldBe(JSON.stringify(JSON.parse(source)), text, "JSON.parse " + kind + " " + depth);
            shouldBe(JSON.stringify(JSON.parse(source, (key, value) => value)), text, "reviver " + kind + " " + depth);
            shouldBe(JSON.stringify(eval("(" + source + ")")), text, "eval " + kind + " " + depth);
        }
    }
}
