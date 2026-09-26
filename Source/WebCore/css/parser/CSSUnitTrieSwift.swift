// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// An import binds the file, not the module, so this file needs its own to name
// `WebCore.CSSUnitType`. CSSUnitType.h shares a submodule with the unit-conversion constants,
// hence `CSSUnitsSwiftTypes`.
internal import WebCore_Private.CSSUnitsSwiftTypes

// MARK: - The CSS unit-type trie
//
// A port of cssPrimitiveValueUnitFromTrie (CSSParserToken.cpp). Resolving the unit here means
// only the `CSSUnitType` crosses to C++, in `CSSParserTokenBits::unit`, since the bits have room
// for one value range and a dimension would need two.
//
// Requires WebCore's Swift code to compile whole-module: under batch mode generic specialization
// does not cross files, and `consumeNumericToken` would call the unspecialized trie.
//
// The C++ folds case with `toASCIILower`, the identity outside 'A'-'Z'. `trieSymbol` does the
// same and maps every code unit >= 0x80 to one sentinel, which is safe because every trie edge is
// 'a'-'z' or '_'.

/// The code units the trie's edges use, plus the sentinel for non-ASCII.
///
/// Named constants because `trieSymbol` returns a `UInt8` and a switch over `UInt8` cannot take
/// character literals.
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

    /// Must not equal any edge above.
    static let nonASCII: UInt8 = 0x80
}

/// `WTF::toASCIILower`, reduced to a trie symbol.
///
/// Must be the checked fold: `toASCIILowerUnchecked` maps '_' to 0x7F,
/// which breaks `__qem`.
@inline(always)
private func trieSymbol(_ character: some CSSCodeUnit) -> UInt8 {
    if character >= 0x41 && character <= 0x5A {
        return UInt8(truncatingIfNeeded: character) &+ 0x20
    }
    if character <= 0x7F {
        return UInt8(truncatingIfNeeded: character)
    }
    return Sym.nonASCII
}

/// `WebCore::cssPrimitiveValueUnitFromTrie`.
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
            // The C++ uses two consecutive `if`s here. They are mutually exclusive, so this is
            // the same trie.
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
                && trieSymbol(data[3]) == Sym.e && trieSymbol(data[4]) == Sym.m
            {
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
