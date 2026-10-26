//
// Copyright (C) 2006 Apple Inc. All rights reserved.
//
// Portions are Copyright (C) 2001-6 mozilla.org
//
// Other contributors:
//   Stuart Parmenter <stuart@mozilla.com>
//
// Copyright (C) 2007-2009 Torch Mobile, Inc.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
//
// Alternatively, the contents of this file may be used under the terms
// of either the Mozilla Public License Version 1.1, found at
// http://www.mozilla.org/MPL/ (the "MPL") or the GNU General Public
// License Version 2.0, found at http://www.fsf.org/copyleft/gpl.html
// (the "GPL"), in which case the provisions of the MPL or the GPL are
// applicable instead of those above.  If you wish to allow use of your
// version of this file only under the terms of one of those two
// licenses (the MPL or the GPL) and not to allow others to use your
// version of this file under the LGPL, indicate your decision by
// deletingthe provisions above and replace them with the notice and
// other provisions required by the MPL or the GPL, as the case may be.
// If you do not delete the provisions above, a recipient may use your
// version of this file under any of the LGPL, the MPL or the GPL.
//

// Swift port of the JPEG metadata parsers in JPEGImageDecoder.cpp: readUint16, readUint32,
// checkExifHeader, readImageOrientation (EXIF APP1 orientation) and isICCMarker,
// readICCProfile (ICC APP2 reassembly). WebCore- and libjpeg-free: the caller passes the
// saved markers (libjpeg's marker_list, in order) as (code, data) pairs. No unsafe code.
//
//  * exifOrientation returns the RAW 16-bit value of the first IFD0 entry with tag 0x112,
//    type SHORT and count 1, or nil when there is none. The caller keeps the C++
//    ImageOrientation::fromEXIFValue(value) (invalid values -> None), and nil -> None.
//  * iccProfile concatenates the payloads of the ICC_PROFILE markers in marker order (like
//    the C++, it does not reorder by sequence number), and returns nil in exactly the C++
//    nullptr cases: a sequence number of 0, a sequence number above the marker count, or
//    no payload bytes at all.

enum JPEGMetadata {
    typealias Marker = (code: UInt8, data: [UInt8])

    static let exifMarker: UInt8 = 0xE0 + 1 // JPEG_APP0 + 1
    static let iccMarker: UInt8 = 0xE0 + 2 // JPEG_APP0 + 2
    static let iccHeaderSize = 14

    static func exifOrientation(markers: [Marker]) -> UInt16? {
        let orientationTag: UInt16 = 0x112
        let shortType: UInt16 = 3
        for marker in markers {
            guard let (isBigEndian, headerIFDOffset) = checkExifHeader(marker) else {
                continue
            }
            let data = marker.data
            let offsetToTiffData = 6 // Account for 'Exif\0<fill byte>' header.
            // checkExifHeader guaranteed data.count >= 14, so the subtraction cannot underflow.
            // An IFD offset that does not fit in Int (>= 2^31, 32-bit Int only) is
            // >= data.count - 6, so it takes the C++ `continue` too; no trapping Int().
            guard data.count >= offsetToTiffData, let ifdOffset = Int(exactly: headerIFDOffset),
                ifdOffset < data.count - offsetToTiffData else {
                continue
            }
            var position = ifdOffset + offsetToTiffData

            // A TIFF image file directory: a uint16 entry count, then that many 12-byte entries
            // (2 bytes tag, 2 bytes type, 4 bytes count, 4 bytes value or offset).
            if data.count - position < 2 {
                continue
            }
            let tagCount = Int(readUint16(data, position, isBigEndian))
            position += 2
            let ifdEntrySize = 12
            var index = 0
            while index < tagCount && data.count - position >= ifdEntrySize {
                let tag = readUint16(data, position, isBigEndian)
                let type = readUint16(data, position + 2, isBigEndian)
                let count = readUint32(data, position + 4, isBigEndian)
                if tag == orientationTag && type == shortType && count == 1 {
                    return readUint16(data, position + 8, isBigEndian)
                }
                index += 1
                position += ifdEntrySize
            }
        }
        return nil
    }

    static func iccProfile(markers: [Marker]) -> [UInt8]? {
        var buffer: [UInt8] = []
        for marker in markers {
            if !isICCMarker(marker) {
                continue
            }
            let sequenceNumber = marker.data[12]
            if sequenceNumber == 0 {
                return nil
            }
            let markerCount = marker.data[13]
            if sequenceNumber > markerCount {
                return nil
            }
            buffer.append(contentsOf: marker.data[iccHeaderSize...])
        }
        return buffer.isEmpty ? nil : buffer
    }

    // MARK: - Private

    private static func readUint16(_ data: [UInt8], _ at: Int, _ isBigEndian: Bool) -> UInt16 {
        if isBigEndian {
            return UInt16(data[at]) << 8 | UInt16(data[at + 1])
        }
        return UInt16(data[at + 1]) << 8 | UInt16(data[at])
    }

    private static func readUint32(_ data: [UInt8], _ at: Int, _ isBigEndian: Bool) -> UInt32 {
        if isBigEndian {
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        return UInt32(data[at + 3]) << 24 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 1]) << 8 | UInt32(data[at])
    }

    /// APP1 data is "Exif\0", a fill byte, then a TIFF header: "II" (little endian) or "MM"
    /// (big endian), uint16 42, uint32 offset of IFD0 relative to the TIFF header.
    private static func checkExifHeader(_ marker: Marker) -> (isBigEndian: Bool, ifdOffset: UInt32)? {
        let exifHeaderSize = 14
        let data = marker.data
        guard marker.code == exifMarker,
            data.count >= exifHeaderSize,
            data[0] == 0x45, data[1] == 0x78, data[2] == 0x69, data[3] == 0x66, data[4] == 0, // "Exif\0"
            // data[5] is a fill byte
            (data[6] == 0x49 && data[7] == 0x49) || (data[6] == 0x4D && data[7] == 0x4D) // "II" / "MM"
        else {
            return nil
        }
        let isBigEndian = data[6] == 0x4D
        if readUint16(data, 8, isBigEndian) != 42 {
            return nil
        }
        return (isBigEndian, readUint32(data, 10, isBigEndian))
    }

    private static func isICCMarker(_ marker: Marker) -> Bool {
        let iccProfileTag: [UInt8] = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00] // "ICC_PROFILE\0"
        return marker.code == iccMarker
            && marker.data.count >= iccHeaderSize
            && marker.data.prefix(iccProfileTag.count).elementsEqual(iccProfileTag)
    }
}
