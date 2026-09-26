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


// `CSSUnitType`, in a header of its own that includes only `<cstdint>`, so that Swift can import
// the one definition C++ uses. CSSUnits.h is not importable: it pulls in WTF's string headers.
//
// `FirstViewportCSSUnitType` and `LastViewportCSSUnitType` are aliases inside the enumerator list,
// and the enumerator after an alias numbers on from it, so moving either renumbers everything
// below. A Swift enum cannot carry duplicate raw values, which is why the enum is declared here.

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
