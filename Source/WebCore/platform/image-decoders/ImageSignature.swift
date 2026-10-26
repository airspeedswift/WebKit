//
// Copyright (C) 2016-2023 Apple Inc. All rights reserved.
// Copyright (C) 2008-2009 Torch Mobile, Inc.
// Copyright (C) Research In Motion Limited 2009-2010. All rights reserved.
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//
//

// Swift port of the image-format signature sniffing in ScalableImageDecoder::create()
// (the !PLATFORM(COCOA) matches*Signature statics, then the non-CG USE(AVIF) check), in
// exactly the C++ branch order: GIF, PNG, ICO|CUR, JPEG, BMP, WebP, AVIF ("ftyp" at 4).
// WebCore-free and allocation-free; no unsafe code.
//
// Like the C++, only the first 14 bytes (the longest signature, "RIFF????WEBPVP") are
// looked at, and data shorter than 14 bytes matches nothing.
// Not ported: matchesJPEGXLSignature (a libjxl call) stays in C++ and runs when this
// returns .none; a port without USE(AVIF) must treat .avifFtyp as .none.

enum ImageSignature: Equatable {
    case gif
    case png
    case ico // ICO or CUR
    case jpeg
    case bmp
    case webp
    case avifFtyp
    case none

    static let lengthOfLongestSignature = 14

    static func classify(_ data: Span<UInt8>) -> ImageSignature {
        if data.count < lengthOfLongestSignature {
            return .none
        }
        // All signatures lie inside the first 14 bytes (the C++ copies exactly these).
        if hasPrefix(data, at: 0, gif87a) || hasPrefix(data, at: 0, gif89a) {
            return .gif
        }
        if hasPrefix(data, at: 0, pngSignature) {
            return .png
        }
        if hasPrefix(data, at: 0, icoSignature) || hasPrefix(data, at: 0, curSignature) {
            return .ico
        }
        if hasPrefix(data, at: 0, jpegSignature) {
            return .jpeg
        }
        if hasPrefix(data, at: 0, bmpSignature) {
            return .bmp
        }
        if hasPrefix(data, at: 0, riff) && hasPrefix(data, at: 8, webpVP) {
            return .webp
        }
        if hasPrefix(data, at: 4, ftyp) {
            return .avifFtyp
        }
        return .none
    }

    private static let gif87a: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61] // "GIF87a"
    private static let gif89a: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61] // "GIF89a"
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let bmpSignature: [UInt8] = [0x42, 0x4D] // "BM"
    private static let icoSignature: [UInt8] = [0x00, 0x00, 0x01, 0x00]
    private static let curSignature: [UInt8] = [0x00, 0x00, 0x02, 0x00]
    private static let riff: [UInt8] = [0x52, 0x49, 0x46, 0x46] // "RIFF"
    private static let webpVP: [UInt8] = [0x57, 0x45, 0x42, 0x50, 0x56, 0x50] // "WEBPVP"
    private static let ftyp: [UInt8] = [0x66, 0x74, 0x79, 0x70] // "ftyp"

    /// spanHasPrefix(contents.subspan(offset), prefix) over the 14-byte copy `contents`.
    private static func hasPrefix(_ data: Span<UInt8>, at offset: Int, _ prefix: [UInt8]) -> Bool {
        let contentsCount = min(data.count, lengthOfLongestSignature)
        if offset > contentsCount || contentsCount - offset < prefix.count {
            return false
        }
        for index in prefix.indices where data[offset + index] != prefix[index] {
            return false
        }
        return true
    }
}
