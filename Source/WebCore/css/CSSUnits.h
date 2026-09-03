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

#pragma once

// `CSSUnitType` itself lives here, split out so that it is self-contained and the CSS
// tokenizer island can take it as its own Clang module and import the real enum rather
// than mirroring it. Everything in this header still declares over it, and every existing
// consumer of CSSUnits.h is unaffected.
#include <WebCore/CSSUnitType.h>

// And the unit-conversion constants, split out for the same reason and in the same shape: the calc
// simplification island's fourteen arithmetic `canonicalize` cases multiply by them, so they have to
// be readable from a boundary module. Every consumer of this header still sees them unchanged.
#include <WebCore/CSSUnitConversions.h>

namespace WTF {
class TextStream;
}

namespace WebCore {

enum class CSSUnitCategory : uint8_t {
    Number,
    Percent,
    AbsoluteLength,
    FontRelativeLength,
    ViewportPercentageLength,
    Angle,
    Time,
    Frequency,
    Resolution,
    Flex,
    Other
};

CSSUnitCategory NODELETE unitCategory(CSSUnitType);
CSSUnitType NODELETE canonicalUnitTypeForCategory(CSSUnitCategory);
CSSUnitType NODELETE canonicalUnitTypeForUnitType(CSSUnitType);
std::optional<double> NODELETE conversionToCanonicalUnitsScaleFactor(CSSUnitType);
bool NODELETE conversionToCanonicalUnitRequiresConversionData(CSSUnitType);
ASCIILiteral unitTypeString(CSSUnitType);

WTF::TextStream& operator<<(WTF::TextStream&, CSSUnitCategory);
WTF::TextStream& operator<<(WTF::TextStream&, CSSUnitType);

} // namespace WebCore
