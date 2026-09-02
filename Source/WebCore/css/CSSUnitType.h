/*
 * (C) 1999-2003 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2008, 2019 Apple Inc. All rights reserved.
 * Copyright (C) 2007 Alexey Proskuryakov <ap@webkit.org>
 * Copyright (C) 2026 Samuel Weinig <sam@webkit.org>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */


// `CSSUnitType`, split out of CSSUnits.h so that exactly one definition is compiled by both
// C++ and Swift.
//
// SELF-CONTAINED ON PURPOSE, and `<cstdint>` is the whole of it. The CSS tokenizer island's
// boundary module in WebCore_Private.modulemap takes this header, and a boundary module that
// reached WebCore's PrivateHeaders umbrella would walk it into JavaScriptCore's private
// headers and fail to compile at all. CSSUnits.h could not be taken directly: it declares
// `unitTypeString` returning `ASCIILiteral` and `conversionToCanonicalUnitsScaleFactor`
// returning `std::optional<double>`, so taking it would pull WTF's string headers into the
// island's view -- and it is not self-contained in the first place, taking `uint8_t`,
// `std::optional`, `ASCIILiteral` and `NODELETE` from whoever includes it.
//
// WHAT THIS REPLACES. The island used to MIRROR this enum: a 70-case `CSSUnitTypeSwift` in
// CSSUnitTrieSwift.swift, pinned to this one by 73 `static_assert`s in CSSTokenizer.cpp. The
// asserts were load-bearing rather than belt-and-braces, because behaviour cannot check a
// mirror here -- the trie can return 63 of these 70 enumerators, so no differential, not even
// an exhaustive one, sees a mis-transcribed `Calc`, `Percentage` or `Integer`. Worse, the two
// aliases below interleave into the enumerator list, and in C++ the enumerator after an alias
// continues from the *alias*, so moving either one renumbers all 27 enumerators beneath it in
// silence. Importing the real enum removes the mirror, the asserts and the hazard together:
// there is now nothing to keep in step.
//
// The aliases are why this is a header split rather than a Swift-side `@c` declaration going
// the other way: Swift enums cannot carry duplicate raw values, so Swift can never be the
// original of this particular pair. C++ produces the numbering and Swift consumes it, which is
// also the direction CSSCalcSwiftNodeKind already runs in.

#pragma once

#include <cstdint>

namespace WebCore {

enum class CSSUnitType : uint8_t {
    Unknown,
    Number,
    Integer,
    Percentage,
    Em,
    Ex,
    Px,
    Cm,
    Mm,
    In,
    Pt,
    Pc,
    Deg,
    Rad,
    Grad,
    Ms,
    S,
    Hz,
    Khz,

    Vw,
    Vh,
    Vmin,
    Vmax,
    Vb,
    Vi,
    Svw,
    Svh,
    Svmin,
    Svmax,
    Svb,
    Svi,
    Lvw,
    Lvh,
    Lvmin,
    Lvmax,
    Lvb,
    Lvi,
    Dvw,
    Dvh,
    Dvmin,
    Dvmax,
    Dvb,
    Dvi,
    FirstViewportCSSUnitType = Vw,
    LastViewportCSSUnitType = Dvi,

    Cqw,
    Cqh,
    Cqi,
    Cqb,
    Cqmin,
    Cqmax,

    Dppx,
    X,
    Dpi,
    Dpcm,
    Fr,
    Q,
    Lh,
    Rlh,

    Turn,
    Rem,
    Rex,
    Cap,
    Rcap,
    Ch,
    Rch,
    Ic,
    Ric,

    Calc,
    CalcPercentageWithAngle,
    CalcPercentageWithLength,

    // This value is used to handle quirky margins in reflow roots (body, td, and th) like WinIE.
    // The basic idea is that a stylesheet can use the value __qem (for quirky em) instead of em.
    // When the quirky value is used, if you're in quirks mode, the margin will collapse away
    // inside a table cell. This quirk is specified in the HTML spec but our impl is different.
    QuirkyEm

    // Note that CSSValue allocates 7 bits for m_primitiveUnitType, so there can be no value here > 127.
};

} // namespace WebCore
