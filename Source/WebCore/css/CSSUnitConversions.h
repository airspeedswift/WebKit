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


// The unit-conversion constants, split out of CSSUnits.h for the same reason CSSUnitType.h
// was: so Swift can read the same constants the C++ reads, rather than transcribing them.
// Self-contained on purpose -- just namespace-scope `constexpr double`, nothing else needed.
//
// CSSUnits.h includes this header, so every existing C++ consumer of `CSS::pixelsPerCm` still
// sees exactly one definition of each constant, and `CSSCalc::canonicalize`'s arithmetic cases
// in Swift (CSSCalcSimplificationSwift.swift) multiply by these same constants.
//
// These stay namespace-scope `constexpr double` rather than members of a struct because that
// form imports into Swift cleanly, while a `static constexpr` data member currently does not.

#pragma once

namespace WebCore {
namespace CSS {

// We always assume 96 CSS pixels in a CSS inch. This is the cold hard truth of the Web.
// At high DPI, we may scale a CSS pixel, but the ratio of the CSS pixel to the so-called
// "absolute" CSS length units like inch and pt is always fixed and never changes.
constexpr double pixelsPerInch = 96;

constexpr double pointsPerInch = 72;
constexpr double picasPerInch = 6;
constexpr double mmPerInch = 25.4;
constexpr double cmPerInch = 2.54;
constexpr double QPerInch = 25.4 * 4.0;

constexpr double pixelsPerCm = pixelsPerInch / cmPerInch;
constexpr double pixelsPerMm = pixelsPerInch / mmPerInch;
constexpr double pixelsPerQ = pixelsPerInch / QPerInch;
constexpr double pixelsPerPt = pixelsPerInch / pointsPerInch;
constexpr double pixelsPerPc = pixelsPerInch / picasPerInch;
constexpr double dppxPerX = 1.0;
constexpr double dppxPerDpi = 1.0 / pixelsPerInch;
constexpr double dppxPerDpcm = cmPerInch / pixelsPerInch;
constexpr double secondsPerMillisecond = 1.0 / 1000.0;
constexpr double hertzPerKilohertz = 1000.0;

} // namespace CSS
} // namespace WebCore
