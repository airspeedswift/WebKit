function shouldBe(actual, expected, msg) {
    if (actual !== expected)
        throw new Error("FAIL " + msg + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected));
}

// Escaped strings with long unescaped runs between the escapes.
{
    let run = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(3);
    let value = "";
    for (let i = 0; i < 50; ++i)
        value += run.slice(0, i) + ["\n", "\"", "\\", "\t", "/", "\u0001", "\u00e9", "\u3042"][i % 8];
    let json = JSON.stringify({ value, list: [value, value] });
    let r = JSON.parse(json);
    shouldBe(r.value, value, "strict value");
    shouldBe(r.list[0], value, "strict list 0");
    shouldBe(r.list[1], value, "strict list 1");

    let e = eval("(" + json + ")");
    shouldBe(e.value, value, "eval value");
    shouldBe(e.list[1], value, "eval list 1");
}

// A run that reaches a raw control character right after an escape is still an error.
{
    let threw = false;
    try {
        JSON.parse('["' + "a".repeat(40) + '\\n' + "b".repeat(40) + '\u0001"]');
    } catch (e) {
        threw = e instanceof SyntaxError;
    }
    shouldBe(threw, true, "control character after escape");
}

// Unterminated escaped string.
{
    let threw = false;
    try {
        JSON.parse('["' + "a".repeat(40) + '\\n' + "b".repeat(40));
    } catch (e) {
        threw = e instanceof SyntaxError;
    }
    shouldBe(threw, true, "unterminated escaped string");
}

// Sloppy-mode single-quoted strings with escapes, where a double quote is ordinary text.
{
    let r = eval("({ a: ['" + "x".repeat(40) + "\\n\"" + "y".repeat(40) + "\\'" + "z".repeat(20) + "'] })");
    shouldBe(r.a[0], "x".repeat(40) + "\n\"" + "y".repeat(40) + "'" + "z".repeat(20), "sloppy single quote");
}

// Strings, single-quoted strings and keys of every length up to 40, with a character that ends or interrupts the
// string at every position, through JSON.parse and eval, at both string widths.

function shouldThrowSyntaxError(f, what) {
    try {
        f();
    } catch (e) {
        if (!(e instanceof SyntaxError))
            throw new Error(what + ": expected a SyntaxError but got " + e);
        return;
    }
    throw new Error(what + ": expected a SyntaxError");
}

function letters(n) {
    let s = "";
    for (let i = 0; i < n; ++i)
        s += String.fromCharCode(0x61 + i % 26);
    return s;
}

function wide(text) { return ("\u0100" + text).substring(1); }

for (let n = 0; n <= 40; ++n) {
    let s = letters(n);
    for (let make of [t => t, wide]) {
        shouldBe(JSON.parse(make('"' + s + '"')), s, "string " + n);
        shouldBe(JSON.parse(make('["' + s + '",1]'))[0], s, "array element " + n);
        shouldBe(Object.keys(JSON.parse(make('{"' + s + '":1}')))[0], s, "key " + n);
        shouldBe(eval(make("('" + s + "')")), s, "single-quoted " + n);
        shouldBe(Object.keys(eval(make("({'" + s + "':1})")))[0], s, "single-quoted key " + n);
        shouldThrowSyntaxError(() => JSON.parse(make('"' + s)), "unterminated " + n);
    }
}

let inserts = [
    ["\\n", "\n"], ["\\\"", "\""], ["\\u0041", "A"], ["'", "'"], ["\u00a2", "\u00a2"], ["\u00dc", "\u00dc"],
    ["\u00ff", "\u00ff"], ["\u0122", "\u0122"], ["\u015c", "\u015c"], ["\u5c00", "\u5c00"], ["\uff22", "\uff22"],
];
for (let p = 0; p <= 34; ++p) {
    let before = letters(p), after = letters(36 - p);
    for (let make of [t => t, wide]) {
        for (let [text, value] of inserts) {
            let expected = before + value + after;
            shouldBe(JSON.parse(make('["' + before + text + after + '"]'))[0], expected, "JSON.parse " + text + " at " + p);
            shouldBe(Object.keys(JSON.parse(make('{"' + before + text + after + '":1}')))[0], expected, "key " + text + " at " + p);
            shouldBe(eval(make('(["' + before + text + after + '"])'))[0], expected, "eval " + text + " at " + p);
        }
        shouldBe(eval(make("(['" + before + '"' + after + "'])"))[0], before + '"' + after, "double quote in single-quoted at " + p);
        shouldBe(eval(make("(['" + before + "\t" + after + "'])"))[0], before + "\t" + after, "tab in single-quoted at " + p);
        shouldThrowSyntaxError(() => JSON.parse(make('["' + before + "\t" + after + '"]')), "tab at " + p);
        shouldThrowSyntaxError(() => JSON.parse(make('["' + before + "\u0001" + after + '"]')), "control at " + p);
    }
}

// Two adjacent characters where the second is one bit away from the first's class, at every position of the first
// 16 characters and around them.
let pairs = [["\t\u0008", true], ["\t\u0001", true], ["\t\t", false], ["\t\"", false], ["'&", false], ["\u001f ", true]];
for (let p = 0; p <= 18; ++p) {
    let before = letters(p), after = letters(20 - p);
    for (let make of [t => t, wide]) {
        for (let [text, control] of pairs) {
            let expected = before + text + after;
            if (!text.includes("'"))
                shouldBe(eval(make("(['" + before + text + after + "'])"))[0], expected, "single-quoted pair " + JSON.stringify(text) + " at " + p);
            if (!text.includes("\""))
                shouldBe(eval(make('(["' + before + text + after + '"])'))[0], expected, "double-quoted pair " + JSON.stringify(text) + " at " + p);
            if (control || text[0] === "\t")
                shouldThrowSyntaxError(() => JSON.parse(make('["' + before + text + after + '"]')), "JSON.parse pair " + JSON.stringify(text) + " at " + p);
        }
        shouldBe(JSON.parse(make('["' + before + "\\\"#" + after + '"]'))[0], before + "\"#" + after, "escaped quote pair at " + p);
    }
}

// Every code unit at the edges of each step of the scan, in a string long enough to reach the 32-character step at
// both widths: controls, '"' and '\' end the string's safe run, and everything else is part of it.
for (let p of [0, 7, 8, 15, 16, 17, 31, 32, 47, 48, 63, 64]) {
    let before = letters(p), after = "x".repeat(71 - p);
    for (let [make, last] of [[t => t, 0xff], [wide, 0xffff]]) {
        for (let c = 0; c <= last; ++c) {
            let unit = String.fromCharCode(c);
            let text = make('["' + before + unit + after + '"]');
            if (c < 0x20 || c === 0x22 || c === 0x5c)
                shouldThrowSyntaxError(() => JSON.parse(text), "code unit " + c + " at " + p);
            else
                shouldBe(JSON.parse(text)[0], before + unit + after, "code unit " + c + " at " + p);
        }
    }
}

// 16-bit strings of characters above 0xFF, some of whose low bytes are a quote or a backslash, with a character that
// ends or interrupts the string around each of the first 16 characters and the 32nd, and strings that start within
// the last 33 characters of the input.
let cjk = "\u4e2d\u5c22\u6587\u5c5c\u2220\uff22\u0122\u8a9e";
function cjkText(n) {
    let s = "";
    for (let i = 0; i < n; ++i)
        s += cjk[i % cjk.length];
    return s;
}
for (let p of [0, 1, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33]) {
    let before = cjkText(p), after = cjkText(40 - p);
    for (let pad of ["", " ", "  ", "   "]) {
        shouldBe(JSON.parse("[" + pad + '"' + before + '"]')[0], before, "16-bit string " + p);
        shouldBe(JSON.parse("[" + pad + '"' + before + "\\n" + after + '"]')[0], before + "\n" + after, "16-bit escape at " + p);
        shouldThrowSyntaxError(() => JSON.parse("[" + pad + '"' + before + "\u0001" + after + '"]'), "16-bit control at " + p);
        shouldBe(JSON.parse(pad + '"' + before + '"' + " ".repeat(p % 3)), before, "16-bit string " + p + " near the end");
        shouldThrowSyntaxError(() => JSON.parse(pad + '"' + before), "16-bit unterminated " + p);
    }
}
