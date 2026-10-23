/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#include "Helpers/Test.h"
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSValueRef.h>
#include <cstdlib>
#include <iomanip>
#include <string>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringView.h>

// Throughput of JavaScript BigInt arithmetic, one TEST per operation and operand size. The operators are not exported,
// so each TEST evaluates a script: the operands are generated from a fixed seed, and run(passes) applies the operation
// to every operand (or pair) the given number of times, keeping the results. By default each TEST runs one pass and
// checks a checksum of its results (their toString(16) text, or the strings themselves). With WEBKIT_RUN_BENCHMARKS=1
// in the environment it then runs a fixed number of passes and prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>",
// where the bytes are the operands' 64-bit digits (or characters, for parsing). Nothing asserts on time.

namespace TestWebKitAPI {

static constexpr auto prelude = R"JS(
var seed = 1;
function reseed(value) { seed = value >>> 0 || 1; }
function next() { let x = seed; x ^= x << 13; x ^= x >>> 17; x ^= x << 5; seed = x >>> 0; return seed; }
function hexDigits(count, high) {
    let s = high === true ? (8 + (next() & 7)).toString(16) : high === false ? (1 + next() % 7).toString(16) : (1 + next() % 15).toString(16);
    for (let i = 1; i < count; ++i)
        s += (next() & 15).toString(16);
    return s;
}
function big(digits, negative, high) {
    if (!digits)
        return 0n;
    const value = BigInt("0x" + hexDigits(16 * digits, high));
    return negative ? -value : value;
}
function decimal(characters, negative) {
    let s = negative ? "-" : "";
    s += 1 + next() % 9;
    for (let i = 1; i < characters; ++i)
        s += next() % 10;
    return s;
}
function negativeX(i, signs) { return signs === "negative" || (signs === "mixed" && (i & 1)) || (signs === "opposite" && (i & 1)); }
function negativeY(i, signs) { return signs === "negative" || (signs === "mixed" && (i & 2)) || (signs === "opposite" && !(i & 1)); }
var A = [], B = [], R = [], bytesPerPass = 0, D1 = 0, D2 = 0;
function pairs(count, xDigits, yDigits, signs, xHigh, yHigh) {
    reseed(count * 65599 + xDigits * 257 + yDigits);
    for (let i = 0; i < count; ++i) {
        A.push(big(xDigits, negativeX(i, signs), xHigh));
        B.push(big(yDigits, negativeY(i, signs), yHigh));
    }
    bytesPerPass = count * 8 * (xDigits + yDigits);
}
function singles(count, digits, signs) {
    reseed(count * 65599 + digits);
    for (let i = 0; i < count; ++i)
        A.push(big(digits, negativeX(i, signs)));
    B = A;
    bytesPerPass = count * 8 * digits;
}
function decimals(count, characters, parsed) {
    reseed(count * 65599 + characters);
    for (let i = 0; i < count; ++i) {
        const s = decimal(characters, i & 1);
        A.push(parsed ? BigInt(s) : s);
    }
    B = A;
    bytesPerPass = count * (parsed ? 8 * ((A[0] < 0n ? -A[0] : A[0]).toString(16).length + 15 >> 4) : characters);
}
function modulus(count, xDigits, m) {
    reseed(count * 65599 + xDigits);
    const mDigits = m.toString(16).length + 15 >> 4;
    for (let i = 0; i < count; ++i) {
        A.push(big(xDigits, i & 1));
        B.push(m);
    }
    bytesPerPass = count * 8 * (xDigits + mDigits);
}
var E = 0n;
function modPow(base, exponent, m) {
    let result = 1n;
    base %= m;
    while (exponent > 0n) {
        if (exponent & 1n)
            result = result * base % m;
        base = base * base % m;
        exponent >>= 1n;
    }
    return result;
}
function modPows(count, digits) {
    reseed(count * 65599 + digits);
    const m = big(digits, false, true) | 1n;
    E = big(digits, false);
    for (let i = 0; i < count; ++i) {
        A.push(big(digits, false) % m);
        B.push(m);
    }
    bytesPerPass = count * 8 * 3 * digits;
}
function digest() {
    let h1 = 0x811c9dc5 | 0, h2 = 0x050c5d1f | 0;
    for (let i = 0; i < R.length; ++i) {
        const value = R[i];
        const s = (typeof value === "string" ? "s" + value : value.toString(16)) + ",";
        for (let j = 0; j < s.length; ++j) {
            const c = s.charCodeAt(j);
            h1 = Math.imul(h1 ^ c, 0x01000193);
            h2 = Math.imul(h2 ^ c ^ (j & 0xff), 0x01000193);
        }
    }
    D1 = h1 >>> 0;
    D2 = h2 >>> 0;
}
)JS"_s;

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

class Context {
public:
    Context()
        : m_context(JSGlobalContextCreate(nullptr))
    {
    }

    ~Context()
    {
        JSGlobalContextRelease(m_context);
    }

    JSValueRef evaluate(const std::string& script)
    {
        auto string = adopt(JSStringCreateWithUTF8CString(script.c_str()));
        JSValueRef exception = nullptr;
        auto* result = JSEvaluateScript(m_context, string.get(), nullptr, nullptr, 1, &exception);
        EXPECT_FALSE(exception) << toString(exception);
        return result;
    }

    std::string toString(JSValueRef value)
    {
        if (!value)
            return { };
        auto string = adopt(JSValueToStringCopy(m_context, value, nullptr));
        if (!string)
            return { };
        std::string result(JSStringGetMaximumUTF8CStringSize(string.get()), '\0');
        result.resize(JSStringGetUTF8CString(string.get(), result.data(), result.size()) - 1);
        return result;
    }

    double toNumber(JSValueRef value)
    {
        return JSValueToNumber(m_context, value, nullptr);
    }

private:
    JSGlobalContextRef m_context;
};

// setup is a call to one of the prelude's generators. body is the statement run for each operand (a) or pair (a, b),
// which appends its results with R[k++] = ....
static void runBenchmark(ASCIILiteral name, ASCIILiteral setup, ASCIILiteral body, unsigned passes, uint64_t expectedChecksum)
{
    Context context;
    context.evaluate(std::string(prelude.characters()) + setup.characters() + ";\nfunction run(passes) { for (let p = 0; p < passes; ++p) { let k = 0; for (let i = 0; i < A.length; ++i) { const a = A[i], b = B[i]; " + body.characters() + " } } }\n");

    context.evaluate("run(1); digest();");
    uint64_t checksum = static_cast<uint64_t>(context.toNumber(context.evaluate("D1"))) << 32 | static_cast<uint64_t>(context.toNumber(context.evaluate("D2")));
    EXPECT_EQ(checksum, expectedChecksum) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum;

    if (!runsBenchmarks())
        return;

    double bytes = context.toNumber(context.evaluate("bytesPerPass")) * passes;
    auto start = MonotonicTime::now();
    context.evaluate("run(" + std::to_string(passes) + ")");
    double seconds = (MonotonicTime::now() - start).seconds();
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum));
}

// Addition and subtraction of one- and two-digit operands, all four sign pairs.
TEST(BigIntBench, AddSub1)
{
    runBenchmark("AddSub1"_s, "pairs(1024, 1, 1, 'mixed')"_s, "R[k++] = a + b; R[k++] = a - b;"_s, 150000, 0x428583ac8208d887ull);
}

TEST(BigIntBench, AddSub2)
{
    runBenchmark("AddSub2"_s, "pairs(1024, 2, 2, 'mixed')"_s, "R[k++] = a + b; R[k++] = a - b;"_s, 140000, 0x6389cdc387b87889ull);
}

// Products at the sizes with fixed-size code, then at the sizes where the algorithm changes.
TEST(BigIntBench, Mul1x1)
{
    runBenchmark("Mul1x1"_s, "pairs(1024, 1, 1, 'mixed')"_s, "R[k++] = a * b;"_s, 250000, 0x568f73741cbb743bull);
}

TEST(BigIntBench, Mul2x2)
{
    runBenchmark("Mul2x2"_s, "pairs(1024, 2, 2, 'mixed')"_s, "R[k++] = a * b;"_s, 220000, 0xa2722f4bccd547e4ull);
}

TEST(BigIntBench, Mul4x4)
{
    runBenchmark("Mul4x4"_s, "pairs(1024, 4, 4, 'mixed')"_s, "R[k++] = a * b;"_s, 160000, 0x52eef619a05af429ull);
}

TEST(BigIntBench, Mul8x8)
{
    runBenchmark("Mul8x8"_s, "pairs(512, 8, 8, 'mixed')"_s, "R[k++] = a * b;"_s, 120000, 0x42a9cc5ae8e0a3aaull);
}

TEST(BigIntBench, Mul16x16)
{
    runBenchmark("Mul16x16"_s, "pairs(256, 16, 16, 'mixed')"_s, "R[k++] = a * b;"_s, 65000, 0x1a1de5398ae73408ull);
}

TEST(BigIntBench, Square1)
{
    runBenchmark("Square1"_s, "singles(1024, 1, 'mixed')"_s, "R[k++] = a * a;"_s, 270000, 0x0e6b5b8bc23d2375ull);
}

TEST(BigIntBench, Square2)
{
    runBenchmark("Square2"_s, "singles(1024, 2, 'mixed')"_s, "R[k++] = a * a;"_s, 240000, 0xb78cff92f2d45690ull);
}

TEST(BigIntBench, Square4)
{
    runBenchmark("Square4"_s, "singles(1024, 4, 'mixed')"_s, "R[k++] = a * a;"_s, 180000, 0x3c8e3646547f8364ull);
}

TEST(BigIntBench, Square8)
{
    runBenchmark("Square8"_s, "singles(512, 8, 'mixed')"_s, "R[k++] = a * a;"_s, 160000, 0x0eaca5d220db6c78ull);
}

TEST(BigIntBench, Square16)
{
    runBenchmark("Square16"_s, "singles(256, 16, 'mixed')"_s, "R[k++] = a * a;"_s, 110000, 0xb03a76f66464373cull);
}

TEST(BigIntBench, Mul2x32)
{
    runBenchmark("Mul2x32"_s, "pairs(512, 2, 32, 'mixed')"_s, "R[k++] = a * b;"_s, 77000, 0xc73264d4c0de663eull);
}

TEST(BigIntBench, Mul5x40)
{
    runBenchmark("Mul5x40"_s, "pairs(512, 5, 40, 'mixed')"_s, "R[k++] = a * b;"_s, 20000, 0x249e608d24b15dd4ull);
}

TEST(BigIntBench, Mul32x32)
{
    runBenchmark("Mul32x32"_s, "pairs(256, 32, 32, 'mixed')"_s, "R[k++] = a * b;"_s, 15000, 0x79025f0a0caeafbaull);
}

TEST(BigIntBench, Mul43x43)
{
    runBenchmark("Mul43x43"_s, "pairs(256, 43, 43, 'mixed')"_s, "R[k++] = a * b;"_s, 8200, 0xe7c2f7fdcdfa1742ull);
}

TEST(BigIntBench, Mul64x64)
{
    runBenchmark("Mul64x64"_s, "pairs(128, 64, 64, 'mixed')"_s, "R[k++] = a * b;"_s, 8600, 0x52b585f603a8b16dull);
}

TEST(BigIntBench, Mul256x256)
{
    runBenchmark("Mul256x256"_s, "pairs(32, 256, 256, 'mixed')"_s, "R[k++] = a * b;"_s, 3500, 0x8783704e4b8b7343ull);
}

TEST(BigIntBench, Mul600x600)
{
    runBenchmark("Mul600x600"_s, "pairs(16, 600, 600, 'mixed')"_s, "R[k++] = a * b;"_s, 1800, 0x72795f3f4da8b0ceull);
}

TEST(BigIntBench, Mul2048x2048)
{
    runBenchmark("Mul2048x2048"_s, "pairs(8, 2048, 2048, 'mixed')"_s, "R[k++] = a * b;"_s, 710, 0x36c3942b946c6495ull);
}

// Division and remainder: Knuth's algorithm, Burnikel-Ziegler, and operands of the same length.
TEST(BigIntBench, Div16By8)
{
    runBenchmark("Div16By8"_s, "pairs(512, 16, 8, 'mixed')"_s, "R[k++] = a / b;"_s, 18000, 0xd9ae020cd88da7b0ull);
}

TEST(BigIntBench, Div60By30)
{
    runBenchmark("Div60By30"_s, "pairs(256, 60, 30, 'mixed')"_s, "R[k++] = a / b;"_s, 4900, 0x754fe22a01133346ull);
}

TEST(BigIntBench, Div1000By100)
{
    runBenchmark("Div1000By100"_s, "pairs(16, 1000, 100, 'mixed')"_s, "R[k++] = a / b;"_s, 1700, 0x57811fabafd1e2b1ull);
}

TEST(BigIntBench, DivSameSize)
{
    runBenchmark("DivSameSize"_s, "pairs(1024, 8, 8, 'mixed', true, false)"_s, "R[k++] = a / b;"_s, 110000, 0x2868edd2a5775688ull);
}

TEST(BigIntBench, ModSameSize)
{
    runBenchmark("ModSameSize"_s, "pairs(1024, 8, 8, 'mixed', true, false)"_s, "R[k++] = a % b;"_s, 73000, 0x74500fb92842114bull);
}

// Repeated remainders by one divisor: a 2048-bit one, and 2^255 - 19.
TEST(BigIntBench, ModCachedBarrett)
{
    runBenchmark("ModCachedBarrett"_s, "modulus(256, 64, big(32, false, true) | 1n)"_s, "R[k++] = a % b;"_s, 12000, 0x0797b2842e448863ull);
}

TEST(BigIntBench, ModCachedFold)
{
    runBenchmark("ModCachedFold"_s, "modulus(1024, 8, (1n << 255n) - 19n)"_s, "R[k++] = a % b;"_s, 150000, 0x8073ae1013a8acc4ull);
}

// Shifts of negative values, which round toward minus infinity.
TEST(BigIntBench, ShiftNeg1)
{
    runBenchmark("ShiftNeg1"_s, "singles(1024, 16, 'negative')"_s, "R[k++] = a << 1n; R[k++] = a >> 1n;"_s, 29000, 0x963a494af84b0f59ull);
}

TEST(BigIntBench, ShiftNeg63)
{
    runBenchmark("ShiftNeg63"_s, "singles(1024, 16, 'negative')"_s, "R[k++] = a << 63n; R[k++] = a >> 63n;"_s, 29000, 0x3546f00ac4692783ull);
}

TEST(BigIntBench, ShiftNeg64)
{
    runBenchmark("ShiftNeg64"_s, "singles(1024, 16, 'negative')"_s, "R[k++] = a << 64n; R[k++] = a >> 64n;"_s, 39000, 0x128fd561ff5f9677ull);
}

TEST(BigIntBench, ShiftNeg1000)
{
    runBenchmark("ShiftNeg1000"_s, "singles(1024, 16, 'negative')"_s, "R[k++] = a << 1000n; R[k++] = a >> 1000n;"_s, 39000, 0x6d384cfaa3c39380ull);
}

// Bitwise operators on two's-complement values of different lengths.
TEST(BigIntBench, BitwiseMixedSigns)
{
    runBenchmark("BitwiseMixedSigns"_s, "pairs(1024, 8, 6, 'opposite')"_s, "R[k++] = a & b; R[k++] = a | b; R[k++] = a ^ b;"_s, 32000, 0xbd705cdd5417c16cull);
}

TEST(BigIntBench, BitwiseNegative)
{
    runBenchmark("BitwiseNegative"_s, "pairs(1024, 8, 6, 'negative')"_s, "R[k++] = a & b; R[k++] = a | b; R[k++] = a ^ b; R[k++] = ~a;"_s, 24000, 0x015eba8e4d240f0dull);
}

TEST(BigIntBench, IncDec)
{
    runBenchmark("IncDec"_s, "pairs(1024, 2, 2, 'mixed')"_s, "let x = a; ++x; R[k++] = x; let y = b; --y; R[k++] = y;"_s, 130000, 0x99c58dc9734e5b07ull);
}

// Conversions to and from strings of 50 and 2000 decimal digits.
TEST(BigIntBench, ToString10Of50)
{
    runBenchmark("ToString10Of50"_s, "decimals(1024, 50, true)"_s, "R[k++] = a.toString(10);"_s, 9300, 0xabf814e1b4fc1a13ull);
}

TEST(BigIntBench, ToString10Of2000)
{
    runBenchmark("ToString10Of2000"_s, "decimals(64, 2000, true)"_s, "R[k++] = a.toString(10);"_s, 330, 0x6171261f5d6b85b5ull);
}

TEST(BigIntBench, ToString16Of50)
{
    runBenchmark("ToString16Of50"_s, "decimals(1024, 50, true)"_s, "R[k++] = a.toString(16);"_s, 30000, 0xa000514ac40c0c00ull);
}

TEST(BigIntBench, ToString16Of2000)
{
    runBenchmark("ToString16Of2000"_s, "decimals(64, 2000, true)"_s, "R[k++] = a.toString(16);"_s, 22000, 0xf7023eb26ae30f4cull);
}

TEST(BigIntBench, Parse10Of50)
{
    runBenchmark("Parse10Of50"_s, "decimals(1024, 50, false)"_s, "R[k++] = BigInt(a);"_s, 25000, 0x9493ea822cecab04ull);
}

TEST(BigIntBench, Parse10Of2000)
{
    runBenchmark("Parse10Of2000"_s, "decimals(64, 2000, false)"_s, "R[k++] = BigInt(a);"_s, 1300, 0xa229c4a45a5fe5d6ull);
}

// Exponentiation, and a 2048-bit modular exponentiation by squaring and multiplying.
TEST(BigIntBench, Pow)
{
    runBenchmark("Pow"_s, "singles(1024, 2, 'mixed')"_s, "R[k++] = a ** 21n;"_s, 5900, 0xee0ff5ce6054bd91ull);
}

TEST(BigIntBench, ModPow2048)
{
    runBenchmark("ModPow2048"_s, "modPows(2, 32)"_s, "R[k++] = modPow(a, E, b);"_s, 270, 0x3423bd07b78c3495ull);
}

} // namespace TestWebKitAPI
