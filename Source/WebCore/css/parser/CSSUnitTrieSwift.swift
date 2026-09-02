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

// The island's boundary types, for `WebCore.CSSUnitType`. Needed here in its own right even
// though CSSTokenizerSwift.swift next door imports the same module: an import binds the FILE,
// not the module, so a `public import` there re-exports to this module's clients but makes
// nothing visible in this file. Until this file named a C++ type it needed no import at all,
// which is why one was never here. Without it `WebCore` resolves to the Swift module of that
// name -- WebCore is both -- and the error is "no type named 'CSSUnitType' in module 'WebCore'",
// which reads like a missing header rather than a missing import.
//
// `internal`, not `public`: nothing this file exposes names the type. The two `@_expose(Cxx)`
// differential entries at the bottom return its `rawValue`, a `UInt8`.
internal import WebCore_Private.CSSTokenizerSwiftTypes

// MARK: - The CSS unit-type trie
//
// In its own file, and that depends on a build setting. WebCore's Swift step is
// `SWIFT_COMPILATION_MODE = wholemodule` (Configurations/WebCore.xcconfig), and without it this
// file cannot exist: Xcode's default for Swift is `-incremental -enable-batch-mode`, and nothing
// specializes across a Swift *file* boundary under it. When the trie last lived here with batch
// mode in force, `consumeNumericToken` did not call the 943-instruction `UInt8` specialization
// that was sitting in the same binary. Per dimension token it called a lazy
// protocol-conformance-witness-table accessor, then the *unspecialized* generic trie -- 17,898
// instructions, every `Span` access through a witness -- then `CSSUnitType.rawValue` out of
// line, twice. That was 10.7 points of the 8-bit real-corpus median (0.879 split, 0.992 in one
// file, each against its own interleaved C++ control), which is why `e5183bac37fd` folded the
// trie into CSSTokenizerSwift.swift and why that commit named -wmo as the build change that
// would let the split stand.
//
// So: if a future edit turns whole-module off for WebCore, this file silently costs those 10.7
// points. The check is a disassembly one and it is cheap -- `nm` the framework for
// `cssPrimitiveValueUnitFromTrie` and confirm the specializations are what
// `consumeNumericToken` calls, not the generic through a witness table.

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

// `WebCore::CSSUnitType` is imported, not mirrored. It used to be a 70-case `@c` enum here,
// pinned to the C++ by 73 `static_assert`s in CSSTokenizer.cpp, because `CSSUnits.h` could not
// join the island's boundary module -- it is not self-contained, and it is a Private header, so
// taking it would have meant excluding it from the `Core` umbrella that seven WebKit Swift files
// import. Splitting the enum alone into a self-contained CSSUnitType.h answers both: `Core`
// excludes only the split header, and CSSUnits.h includes it so no C++ consumer moves.
//
// The mirror was checkable but not free of hazard, which is why removing it is worth a header:
// the trie can return only 63 of the 70 enumerators, so no behavioural differential, however
// exhaustive, could have caught a mis-transcribed `Calc`, `Percentage` or `Integer` -- the
// asserts were the only thing standing there. Now there is nothing to keep in step.

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
func cssPrimitiveValueUnitFromTrie<Unit: CSSCodeUnit>(_ data: Span<Unit>) -> WebCore.CSSUnitType {
    switch data.count {
    case 1:
        switch trieSymbol(data[0]) {
        case Sym.q:
            return .Q
        case Sym.s:
            return .S
        case Sym.x:
            return .X
        default:
            break
        }

    case 2:
        switch trieSymbol(data[0]) {
        case Sym.c:
            switch trieSymbol(data[1]) {
            case Sym.h:
                return .Ch
            case Sym.m:
                return .Cm
            default:
                break
            }
        case Sym.e:
            switch trieSymbol(data[1]) {
            case Sym.m:
                return .Em
            case Sym.x:
                return .Ex
            default:
                break
            }
        case Sym.f:
            if trieSymbol(data[1]) == Sym.r {
                return .Fr
            }
        case Sym.h:
            if trieSymbol(data[1]) == Sym.z {
                return .Hz
            }
        case Sym.i:
            switch trieSymbol(data[1]) {
            case Sym.c:
                return .Ic
            case Sym.n:
                return .In
            default:
                break
            }
        case Sym.l:
            if trieSymbol(data[1]) == Sym.h {
                return .Lh
            }
        case Sym.m:
            switch trieSymbol(data[1]) {
            case Sym.m:
                return .Mm
            case Sym.s:
                return .Ms
            default:
                break
            }
        case Sym.p:
            switch trieSymbol(data[1]) {
            case Sym.c:
                return .Pc
            case Sym.t:
                return .Pt
            case Sym.x:
                return .Px
            default:
                break
            }
        case Sym.v:
            switch trieSymbol(data[1]) {
            case Sym.b:
                return .Vb
            case Sym.h:
                return .Vh
            case Sym.i:
                return .Vi
            case Sym.w:
                return .Vw
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
                    return .Cap
                }
            }
            if trieSymbol(data[1]) == Sym.q {
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .Cqb
                case Sym.h:
                    return .Cqh
                case Sym.i:
                    return .Cqi
                case Sym.w:
                    return .Cqw
                default:
                    break
                }
            }
        case Sym.d:
            switch trieSymbol(data[1]) {
            case Sym.e:
                if trieSymbol(data[2]) == Sym.g {
                    return .Deg
                }
            case Sym.p:
                if trieSymbol(data[2]) == Sym.i {
                    return .Dpi
                }
            case Sym.v:
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .Dvb
                case Sym.h:
                    return .Dvh
                case Sym.i:
                    return .Dvi
                case Sym.w:
                    return .Dvw
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
                    return .Lvb
                case Sym.h:
                    return .Lvh
                case Sym.i:
                    return .Lvi
                case Sym.w:
                    return .Lvw
                default:
                    break
                }
            }
        case Sym.k:
            if trieSymbol(data[1]) == Sym.h && trieSymbol(data[2]) == Sym.z {
                return .Khz
            }
        case Sym.r:
            switch trieSymbol(data[1]) {
            case Sym.a:
                if trieSymbol(data[2]) == Sym.d {
                    return .Rad
                }
            case Sym.c:
                if trieSymbol(data[2]) == Sym.h {
                    return .Rch
                }
            case Sym.e:
                if trieSymbol(data[2]) == Sym.m {
                    return .Rem
                }
                if trieSymbol(data[2]) == Sym.x {
                    return .Rex
                }
            case Sym.i:
                if trieSymbol(data[2]) == Sym.c {
                    return .Ric
                }
            case Sym.l:
                if trieSymbol(data[2]) == Sym.h {
                    return .Rlh
                }
            default:
                break
            }
        case Sym.s:
            if trieSymbol(data[1]) == Sym.v {
                switch trieSymbol(data[2]) {
                case Sym.b:
                    return .Svb
                case Sym.h:
                    return .Svh
                case Sym.i:
                    return .Svi
                case Sym.w:
                    return .Svw
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
                        return .Dpcm
                    }
                case Sym.p:
                    if trieSymbol(data[3]) == Sym.x {
                        return .Dppx
                    }
                default:
                    break
                }
            default:
                break
            }
        case Sym.g:
            if trieSymbol(data[1]) == Sym.r && trieSymbol(data[2]) == Sym.a && trieSymbol(data[3]) == Sym.d {
                return .Grad
            }
        case Sym.r:
            if trieSymbol(data[1]) == Sym.c && trieSymbol(data[2]) == Sym.a && trieSymbol(data[3]) == Sym.p {
                return .Rcap
            }
        case Sym.t:
            if trieSymbol(data[1]) == Sym.u && trieSymbol(data[2]) == Sym.r && trieSymbol(data[3]) == Sym.n {
                return .Turn
            }
        case Sym.v:
            switch trieSymbol(data[1]) {
            case Sym.m:
                switch trieSymbol(data[2]) {
                case Sym.a:
                    if trieSymbol(data[3]) == Sym.x {
                        return .Vmax
                    }
                case Sym.i:
                    if trieSymbol(data[3]) == Sym.n {
                        return .Vmin
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
                return .QuirkyEm
            }
        case Sym.c:
            if trieSymbol(data[1]) == Sym.q && trieSymbol(data[2]) == Sym.m {
                switch trieSymbol(data[3]) {
                case Sym.a:
                    if trieSymbol(data[4]) == Sym.x {
                        return .Cqmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .Cqmin
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
                        return .Dvmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .Dvmin
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
                        return .Lvmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .Lvmin
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
                        return .Svmax
                    }
                case Sym.i:
                    if trieSymbol(data[4]) == Sym.n {
                        return .Svmin
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
    return .Unknown
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
