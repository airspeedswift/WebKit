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

// The CSS unit-type trie, in Swift.
//
//   Source/WebCore/css/parser/CSSParserToken.cpp  cssPrimitiveValueUnitFromTrie (304 lines)
//   Source/WebCore/css/CSSUnits.h                 enum class CSSUnitType
//
// Why this is here. `CSSParserToken::stringToUnitType` is the only reason a DimensionToken's
// *unit text* has to reach C++ at all: the island hands back the unit's range so that C++ can
// run the trie over it. `CSSParserTokenBits` has room for exactly one value range, and a
// dimension needs two -- the number's text and the unit's text -- so for as long as the unit
// is resolved on the far side, the island cannot emit a finished token for the one token type
// that carries the most information. Resolving the unit here collapses that: the unit range
// stops crossing, and only the resolved `CSSUnitType` does, in the seven bits
// `CSSParserTokenBits::unit` already reserves for it.
//
// FAITHFULNESS. This is a transcription, not a redesign: the length dispatch, the per-index
// nesting and the order of the comparisons are the C++'s. There is exactly one structural
// change, and it is the one that lets a single body serve both widths:
//
//   The C++ writes `switch (toASCIILower(data[i]))`, where `toASCIILower` is
//   `character | (isASCIIUpper(character) << 5)` for char16_t (ASCIICType.h:189) and a
//   256-entry `asciiCaseFoldTable` lookup for Latin1Character (ASCIICType.h:199). That table
//   (ASCIICType.cpp:30) is the identity outside 'A'-'Z', so BOTH spellings fold 'A'-'Z' and
//   nothing else -- in particular Latin-1 uppercase 0xC0-0xDE is NOT folded, and neither is
//   any non-ASCII UTF-16 code unit. Here that becomes `trieSymbol`, which folds 'A'-'Z',
//   passes the rest of ASCII through, and collapses everything >= 0x80 to a single sentinel.
//   Collapsing is behaviour-preserving because every edge in the trie is 'a'-'z' or '_', so
//   no code unit >= 0x80 can match one either before or after folding.
//
// PROOF. Not argued, measured. `~/src/webkit-swift-ports/css-unit-trie` compares this body
// against a verbatim extraction of the tree's own function over 873,806,013 distinct inputs
// (922,068,940 comparisons, 0 mismatches, all 63 reachable units produced), and five
// deliberately wrong ports are each caught by the phase aimed at them. The in-tree copies are
// then compared against each other by the unit-trie phase of
// `~/src/webkit-swift-ports/cssprobe/validate/csscheck.cpp`, through the entry points at the
// bottom of this file -- because two of my own extractions agreeing is not the claim; the
// claim is that the function WebCore ships and the function this island runs agree.
//
// SAFETY. Zero `unsafe` markers. Every read is a bounds-checked `Span` subscript. The C++ has
// an `ASSERT(data.data())` that is a no-op in Release, so a null span there is unchecked;
// here the empty case is just `count == 0`, which is a real check rather than an assertion.

/// Mirrors `WebCore::CSSUnitType` (`Source/WebCore/css/CSSUnits.h`).
///
/// A mirror rather than the imported enum, and the reason is the boundary module rather than
/// anything about the type. The island imports `WebCore_Private.CSSTokenizerSwiftTypes`, whose
/// whole point is that it is *not* the WebCore umbrella (see CSSTokenizerSwiftTypes.h), and
/// `CSSUnits.h` cannot join it: it has no `#include`s at all and leans on its includer for
/// `uint8_t`, `std::optional`, `ASCIILiteral` and `NODELETE`, so it is not self-contained; and
/// it is a Private header, so putting it in the island's module means excluding it from the
/// `Core` umbrella and taking `CSSUnitType` away from every other Swift file that imports
/// WebCore_Private. Mirroring costs 70 lines and no build risk.
///
/// `@c` (SE-0495) is what makes the mirror checkable rather than hopeful. It emits this into
/// WebCoreSwift-Generated.h as a `uint8_t`-backed C enum, so CSSTokenizer.cpp can `static_assert`
/// each C++ enumerator against `CSSUnitTypeSwift<Name>` **by name**, for all 70. That is not
/// pedantry: `CSSUnitType` interleaves the aliases `FirstViewportCSSUnitType = Vw` and
/// `LastViewportCSSUnitType = Dvi` into the enumerator list, and the enumerator after an alias
/// continues from the *alias*, so moving either one silently renumbers everything below it.
/// The trie can only return 63 of the 70, so a behavioural differential -- however exhaustive --
/// would never catch a mis-transcribed `Calc`, `Percentage` or `Integer`. The aliases are not
/// cases here; Swift enums cannot carry duplicate raw values, and the asserts cover them
/// against `Vw` and `Dvi` directly.
///
/// Internal rather than `public` for the reason given on `CSSTokenTypeSwift`: `@c` on a
/// *resilient* enum crashes IRGen, and WebCore compiles Swift with -enable-library-evolution.
/// The generated header is emitted at `-emit-clang-header-min-access internal`, so internal
/// loses nothing.
@c
enum CSSUnitTypeSwift: UInt8 {
    case unknown = 0
    case number = 1
    case integer = 2
    case percentage = 3
    case em = 4
    case ex = 5
    case px = 6
    case cm = 7
    case mm = 8
    case `in` = 9
    case pt = 10
    case pc = 11
    case deg = 12
    case rad = 13
    case grad = 14
    case ms = 15
    case s = 16
    case hz = 17
    case khz = 18

    case vw = 19
    case vh = 20
    case vmin = 21
    case vmax = 22
    case vb = 23
    case vi = 24
    case svw = 25
    case svh = 26
    case svmin = 27
    case svmax = 28
    case svb = 29
    case svi = 30
    case lvw = 31
    case lvh = 32
    case lvmin = 33
    case lvmax = 34
    case lvb = 35
    case lvi = 36
    case dvw = 37
    case dvh = 38
    case dvmin = 39
    case dvmax = 40
    case dvb = 41
    case dvi = 42

    case cqw = 43
    case cqh = 44
    case cqi = 45
    case cqb = 46
    case cqmin = 47
    case cqmax = 48

    case dppx = 49
    case x = 50
    case dpi = 51
    case dpcm = 52
    case fr = 53
    case q = 54
    case lh = 55
    case rlh = 56

    case turn = 57
    case rem = 58
    case rex = 59
    case cap = 60
    case rcap = 61
    case ch = 62
    case rch = 63
    case ic = 64
    case ric = 65

    case calc = 66
    case calcPercentageWithAngle = 67
    case calcPercentageWithLength = 68

    /// `__qem`, the quirky-em unit. See the comment on the C++ enumerator.
    case quirkyEm = 69
}

/// The ASCII code units the trie's edges are drawn from, plus the sentinel every non-ASCII
/// code unit folds to.
///
/// Named constants rather than character literals because `trieSymbol` returns a `UInt8` for
/// both widths, and `case "q"` in a switch over `UInt8` is not a thing Swift will write for
/// you. The alphabet is 'a'-'z' minus j, o and y, plus '_'.
private enum Sym {
    static let a = UInt8(ascii: "a")
    static let b = UInt8(ascii: "b")
    static let c = UInt8(ascii: "c")
    static let d = UInt8(ascii: "d")
    static let e = UInt8(ascii: "e")
    static let f = UInt8(ascii: "f")
    static let g = UInt8(ascii: "g")
    static let h = UInt8(ascii: "h")
    static let i = UInt8(ascii: "i")
    static let k = UInt8(ascii: "k")
    static let l = UInt8(ascii: "l")
    static let m = UInt8(ascii: "m")
    static let n = UInt8(ascii: "n")
    static let p = UInt8(ascii: "p")
    static let q = UInt8(ascii: "q")
    static let r = UInt8(ascii: "r")
    static let s = UInt8(ascii: "s")
    static let t = UInt8(ascii: "t")
    static let u = UInt8(ascii: "u")
    static let v = UInt8(ascii: "v")
    static let w = UInt8(ascii: "w")
    static let x = UInt8(ascii: "x")
    static let z = UInt8(ascii: "z")
    static let underscore = UInt8(ascii: "_")

    /// Stands in for every code unit >= 0x80. Must not collide with any edge above; all of
    /// those are 'a'-'z' (0x61-0x7A) or '_' (0x5F).
    static let nonASCII: UInt8 = 0x80
}

/// `WTF::toASCIILower`, folded into "the symbol this code unit can match in the trie".
///
/// Folds 'A'-'Z' to 'a'-'z' and nothing else -- matching both `toASCIILower` overloads, which
/// agree because `asciiCaseFoldTable` is the identity outside 'A'-'Z'.
///
/// This is the *checked* fold, and the distinction is load-bearing for exactly one unit. WTF
/// also has `toASCIILowerUnchecked` (`character | 0x20`), and ASCIICType.h:82 explicitly
/// recommends it "in the CSS tokenizer, for example" -- but it maps '_' (0x5F) to 0x7F, and
/// '_' is the alphabet of `__qem`, the one unit that is not spelled in letters. The unchecked
/// fold would also map '@'->'`' and '['->'{'. Reaching for the faster fold here would pass
/// every test that does not contain a quirky-em; the standalone differential's `unchecked-fold`
/// mutant is exactly that bug, and it fails on 13 inputs, all of them spellings of `__qem`.
@inline(always) private func trieSymbol(_ character: some CSSCodeUnit) -> UInt8 {
    if character >= 0x41 && character <= 0x5A {
        return UInt8(truncatingIfNeeded: character) &+ 0x20
    }
    if character <= 0x7F {
        return UInt8(truncatingIfNeeded: character)
    }
    return Sym.nonASCII
}

/// `WebCore::cssPrimitiveValueUnitFromTrie`.
///
/// `CSSParserToken::stringToUnitType` is a two-line width dispatch onto the C++ template
/// (`CSSParserToken.cpp`); it has no counterpart here because the island already knows
/// statically which width it holds.
func cssPrimitiveValueUnitFromTrie<Unit: CSSCodeUnit>(_ data: Span<Unit>) -> CSSUnitTypeSwift {
    switch data.count {
    case 1:
        switch trieSymbol(data[0]) {
        case Sym.q:
            return .q
        case Sym.s:
            return .s
        case Sym.x:
            return .x
        default:
            break
        }

    case 2:
        switch trieSymbol(data[0]) {
        case Sym.c:
            switch trieSymbol(data[1]) {
            case Sym.h:
                return .ch
            case Sym.m:
                return .cm
            default:
                break
            }
        case Sym.e:
            switch trieSymbol(data[1]) {
            case Sym.m:
                return .em
            case Sym.x:
                return .ex
            default:
                break
            }
        case Sym.f:
            if trieSymbol(data[1]) == Sym.r {
                return .fr
            }
        case Sym.h:
            if trieSymbol(data[1]) == Sym.z {
                return .hz
            }
        case Sym.i:
            switch trieSymbol(data[1]) {
            case Sym.c:
                return .ic
            case Sym.n:
                return .in
            default:
                break
            }
        case Sym.l:
            if trieSymbol(data[1]) == Sym.h {
                return .lh
            }
        case Sym.m:
            switch trieSymbol(data[1]) {
            case Sym.m:
                return .mm
            case Sym.s:
                return .ms
            default:
                break
            }
        case Sym.p:
            switch trieSymbol(data[1]) {
            case Sym.c:
                return .pc
            case Sym.t:
                return .pt
            case Sym.x:
                return .px
            default:
                break
            }
        case Sym.v:
            switch trieSymbol(data[1]) {
            case Sym.b:
                return .vb
            case Sym.h:
                return .vh
            case Sym.i:
                return .vi
            case Sym.w:
                return .vw
            default:
                break
            }
        default:
            break
        }

    case 3:
        switch trieSymbol(data[0]) {
        case Sym.c:
            // The C++ spells these as two consecutive `if`s rather than a switch, with no
            // `break` between them; they are mutually exclusive, so this is the same trie.
            // Copied as it stands, because the shape is a latent bug worth leaving visible:
            // a future `ca?` unit added under the first `if` without a break would be
            // reachable from the second test's failure path.
            if trieSymbol(data[1]) == Sym.a {
                if trieSymbol(data[2]) == Sym.p {
                    return .cap
                }
            }
            if trieSymbol(data[1]) == Sym.q {
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .cqb
                case Sym.h:
                    return .cqh
                case Sym.i:
                    return .cqi
                case Sym.w:
                    return .cqw
                default:
                    break
                }
            }
        case Sym.d:
            switch trieSymbol(data[1]) {
            case Sym.e:
                if trieSymbol(data[2]) == Sym.g {
                    return .deg
                }
            case Sym.p:
                if trieSymbol(data[2]) == Sym.i {
                    return .dpi
                }
            case Sym.v:
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .dvb
                case Sym.h:
                    return .dvh
                case Sym.i:
                    return .dvi
                case Sym.w:
                    return .dvw
                default:
                    break
                }
            default:
                break
            }
        case Sym.l:
            if trieSymbol(data[1]) == Sym.v {
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .lvb
                case Sym.h:
                    return .lvh
                case Sym.i:
                    return .lvi
                case Sym.w:
                    return .lvw
                default:
                    break
                }
            }
        case Sym.k:
            if trieSymbol(data[1]) == Sym.h && trieSymbol(data[2]) == Sym.z {
                return .khz
            }
        case Sym.r:
            switch trieSymbol(data[1]) {
            case Sym.a:
                if trieSymbol(data[2]) == Sym.d {
                    return .rad
                }
            case Sym.c:
                if trieSymbol(data[2]) == Sym.h {
                    return .rch
                }
            case Sym.e:
                if trieSymbol(data[2]) == Sym.m {
                    return .rem
                }
                if trieSymbol(data[2]) == Sym.x {
                    return .rex
                }
            case Sym.i:
                if trieSymbol(data[2]) == Sym.c {
                    return .ric
                }
            case Sym.l:
                if trieSymbol(data[2]) == Sym.h {
                    return .rlh
                }
            default:
                break
            }
        case Sym.s:
            if trieSymbol(data[1]) == Sym.v {
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .svb
                case Sym.h:
                    return .svh
                case Sym.i:
                    return .svi
                case Sym.w:
                    return .svw
                default:
                    break
                }
            }
        default:
            break
        }

    case 4:
        switch trieSymbol(data[0]) {
        case Sym.d:
            switch trieSymbol(data[1]) {
            case Sym.p:
                switch trieSymbol(data[2]) {
                case Sym.c:
                    if trieSymbol(data[3]) == Sym.m {
                        return .dpcm
                    }
                case Sym.p:
                    if trieSymbol(data[3]) == Sym.x {
                        return .dppx
                    }
                default:
                    break
                }
            default:
                break
            }
        case Sym.g:
            if trieSymbol(data[1]) == Sym.r && trieSymbol(data[2]) == Sym.a && trieSymbol(data[3]) == Sym.d {
                return .grad
            }
        case Sym.r:
            if trieSymbol(data[1]) == Sym.c && trieSymbol(data[2]) == Sym.a && trieSymbol(data[3]) == Sym.p {
                return .rcap
            }
        case Sym.t:
            if trieSymbol(data[1]) == Sym.u && trieSymbol(data[2]) == Sym.r && trieSymbol(data[3]) == Sym.n {
                return .turn
            }
        case Sym.v:
            switch trieSymbol(data[1]) {
            case Sym.m:
                switch trieSymbol(data[2]) {
                case Sym.a:
                    if trieSymbol(data[3]) == Sym.x {
                        return .vmax
                    }
                case Sym.i:
                    if trieSymbol(data[3]) == Sym.n {
                        return .vmin
                    }
                default:
                    break
                }
            default:
                break
            }
        default:
            break
        }

    case 5:
        switch trieSymbol(data[0]) {
        case Sym.underscore:
            if trieSymbol(data[1]) == Sym.underscore && trieSymbol(data[2]) == Sym.q
                && trieSymbol(data[3]) == Sym.e && trieSymbol(data[4]) == Sym.m {
                return .quirkyEm
            }
        case Sym.c:
            if trieSymbol(data[1]) == Sym.q && trieSymbol(data[2]) == Sym.m {
                switch trieSymbol(data[3]) {
                case Sym.a:
                    if trieSymbol(data[4]) == Sym.x {
                        return .cqmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .cqmin
                    }
                default:
                    break
                }
            }
        case Sym.d:
            if trieSymbol(data[1]) == Sym.v && trieSymbol(data[2]) == Sym.m {
                switch trieSymbol(data[3]) {
                case Sym.a:
                    if trieSymbol(data[4]) == Sym.x {
                        return .dvmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .dvmin
                    }
                default:
                    break
                }
            }
        case Sym.l:
            if trieSymbol(data[1]) == Sym.v && trieSymbol(data[2]) == Sym.m {
                switch trieSymbol(data[3]) {
                case Sym.a:
                    if trieSymbol(data[4]) == Sym.x {
                        return .lvmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .lvmin
                    }
                default:
                    break
                }
            }
        case Sym.s:
            if trieSymbol(data[1]) == Sym.v && trieSymbol(data[2]) == Sym.m {
                switch trieSymbol(data[3]) {
                case Sym.a:
                    if trieSymbol(data[4]) == Sym.x {
                        return .svmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .svmin
                    }
                default:
                    break
                }
            }
        default:
            break
        }

    default:
        break
    }
    return .unknown
}

#if ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE

// MARK: - Validation entry points
//
// Reachable only from CSSTokenizerSwiftBridge.cpp, and compiled only when
// WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES, which is off by default -- so none of this is in a
// shipping WebCore.framework, and `nm` on a default build shows no new symbol. Same rule as
// the bridge's C++ side, for the same reason: an entry point that exists only to prove the
// island right has no business in the product.
//
// WHY THE INPUT ARRIVES PACKED INTO WORDS. A Swift *callee* cannot take a `Span`. The
// `__counted_by` + `noescape` recipe that gives `CSSSwiftTokenSink::takeChunk` a safe `Span`
// parameter works in the C++-callee direction only; there is no annotation that makes a
// C++ caller hand a Swift function a bounds-checked buffer, and the alternatives -- an
// `UnsafeRawBufferPointer` parameter, or `Span(_unsafeCxxSpan:)` on a `std::span` -- are the
// `unsafe` constructs this file is required not to contain. Filings register §27, seen from
// the argument side rather than the return side.
//
// So the harness passes up to 16 code units by value, little-endian within each word, and the
// entry point rebuilds them into an `InlineArray` on the stack: no allocation, no pointer, no
// `unsafe`, and the exact length the caller asked for via `Span.extracting`. 16 is enough for
// every phase the differential runs (the longest unit is 5 characters; the fuzz phase reaches
// 12), and the cap is a `precondition` rather than a silent clamp, because a truncated input
// silently agreeing with a truncated oracle is precisely the vacuous pass this harness exists
// to rule out.

/// The most code units a validation call can carry. See the note above.
private let maximumPackedCodeUnits = 16

/// `cssPrimitiveValueUnitFromTrie` over Latin-1 text, for the differential.
///
/// Bytes are packed eight to a word, least significant byte first: byte `i` is
/// `(i < 8 ? packed0 : packed1) >> (8 * (i % 8))`.
@_expose(Cxx)
public func cssUnitTrieSwiftLookup8(_ packed0: UInt64, _ packed1: UInt64, _ count: Int) -> UInt8 {
    precondition(count >= 0 && count <= maximumPackedCodeUnits)
    var units = InlineArray<16, UInt8>(repeating: 0)
    for i in 0..<count {
        let word = i < 8 ? packed0 : packed1
        units[i] = UInt8(truncatingIfNeeded: word >> (8 * UInt64(i % 8)))
    }
    return cssPrimitiveValueUnitFromTrie(units.span.extracting(0..<count)).rawValue
}

/// `cssPrimitiveValueUnitFromTrie` over UTF-16 text, for the differential.
///
/// Code units are packed four to a word, least significant first: unit `i` comes from
/// `packed[i / 4] >> (16 * (i % 4))`.
@_expose(Cxx)
public func cssUnitTrieSwiftLookup16(_ packed0: UInt64, _ packed1: UInt64, _ packed2: UInt64, _ packed3: UInt64, _ count: Int) -> UInt8 {
    precondition(count >= 0 && count <= maximumPackedCodeUnits)
    var units = InlineArray<16, UInt16>(repeating: 0)
    for i in 0..<count {
        let word: UInt64
        switch i / 4 {
        case 0: word = packed0
        case 1: word = packed1
        case 2: word = packed2
        default: word = packed3
        }
        units[i] = UInt16(truncatingIfNeeded: word >> (16 * UInt64(i % 4)))
    }
    return cssPrimitiveValueUnitFromTrie(units.span.extracting(0..<count)).rawValue
}

#endif // ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE
