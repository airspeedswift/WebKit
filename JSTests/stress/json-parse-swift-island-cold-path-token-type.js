//@ requireOptions("--useDollarVM=1", "--useSwiftJSONParser=true")

// Cold-path coverage for the Swift JSON island: strings that leave its SIMD fast scan,
// because they carry an escape or because they are never terminated. The island decodes
// the escapes itself and formats the diagnostic for a malformed document itself, so every
// case below must throw a SyntaxError whose message is byte-identical to the one the C++
// parser produces for the same input. A document the island cannot finish is instead
// re-parsed in C++ from the top, which produces that same text the slow way, so a
// mismatch here is the island's message and nothing else.
//
// The inputs reach the cold path both as a document's first token and after other tokens,
// at every length that picks a different scan (below the vector stride, exactly one
// vector, several), and mix escapes with raw control characters, which strict JSON
// rejects.

function shouldThrowWithMessage(text, expected) {
    // Both widths, because the island is instantiated for both and takes a different
    // scan at each: 8-bit is what ASCII JSON actually gets, 16-bit is what the wide
    // instantiation sees.
    var inputs = [text, $vm.make16BitStringIfPossible(text)];
    for (var i = 0; i < inputs.length; ++i) {
        var message = "did not throw";
        try {
            var result = JSON.parse(inputs[i]);
            throw new Error("FAIL " + JSON.stringify(text) + ": returned " + String(result)
                + " instead of throwing");
        } catch (error) {
            if (!(error instanceof SyntaxError))
                throw error;
            message = error.message;
        }
        if (message !== expected) {
            throw new Error("FAIL " + JSON.stringify(text) + ": threw \"" + message
                + "\", expected \"" + expected + "\"");
        }
    }
}

// An escape and a raw control character in the same string: strict JSON stops at
// the control character, so the string is unterminated. These reach the cold path
// somewhere other than the first token.
var escapeThenControl = [
    "\"b\t\u00ff\\n\"",
    "\"bb\t\\nb\"",
    "\"\\\\a\\\\\t\u00e9\u00ff\"",
    "\"\\na\t\\n00\"",
    "\"a\u00ff0\\n\t\\\\b\"",
    "\"\u00ff\t\\n\\\"\\n\\\\\"",
    "\"aa\\\"zz\\\\\u00e9\t\u00ff\"",
    "\"\\\\\t\\u0041a0\\\"\"",
];

// A cold path as the document's *first* token.
var firstTokenColdPath = [
    '"aaaaaaaaaa',              // unterminated, long enough for the SIMD scan
    '"aaaaaaaa',                // exactly one vector
    '"aaa',                     // below the vector stride, scalar scan
    '"',                        // empty and unterminated
    '"abc\\',                   // trailing escape at end of input
    '"abc\\u00',                // truncated unicode escape
    '["aaaaaaaaaaaa',           // unterminated inside a container
    '{"k":"aaaaaaaaaaaa',       // unterminated as a property value
];

for (var iteration = 0; iteration < testLoopCount; ++iteration) {
    for (var i = 0; i < escapeThenControl.length; ++i)
        shouldThrowWithMessage(escapeThenControl[i], "JSON Parse error: Unterminated string");
    for (var i = 0; i < firstTokenColdPath.length; ++i) {
        var text = firstTokenColdPath[i];
        var expected = text === '"abc\\u00'
            ? "JSON Parse error: \\u must be followed by 4 hex digits"
            : "JSON Parse error: Unterminated string";
        shouldThrowWithMessage(text, expected);
    }
}
