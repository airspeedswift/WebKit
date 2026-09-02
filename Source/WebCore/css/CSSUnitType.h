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
// Self-contained on purpose -- `<cstdint>` is the whole of it. The Clang submodule Swift
// imports this from cannot pull in WebCore's PrivateHeaders umbrella (it would walk into
// JavaScriptCore's private headers and fail to compile), and CSSUnits.h is not eligible
// directly: it is not self-contained either, and it declares `unitTypeString` and
// `conversionToCanonicalUnitsScaleFactor`, which would pull WTF's string headers along with it.
//
// `FirstViewportCSSUnitType` and `LastViewportCSSUnitType` are aliases interleaved into the
// enumerator list; the enumerator after an alias continues numbering from the alias, so moving
// either one renumbers every enumerator below it. Swift enums cannot carry duplicate raw
// values, so this is a header split rather than a Swift-side `@c` declaration going the other
// way -- C++ produces the numbering and Swift consumes it.

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
