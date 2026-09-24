/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

// The AV1 bitstream readers of AV1Utilities.cpp, in Swift: the av1C decoder configuration record,
// the sequence header OBU and the codecs parameter string, plus the record validators. Every input
// is handled here, including truncated or malformed data.
//
// The boundary is @_cdecl because WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO, so C++ cannot
// name a Swift declaration. The C++ caller passes the bytes and the address of a default-
// constructed WebCore::AV1CodecConfigurationRecord; on success Swift assigns every field the
// parse determines (codecName is left to C++) and returns true. A field the parse does not
// determine keeps its default. On failure the record contents do not matter.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_AV1_UTILITIES_SWIFT to swiftc for a truthy ENABLE() macro.

#if ENABLE_AV1_UTILITIES_SWIFT

internal import WebCore_Private

private typealias AV1CodecConfigurationRecord = WebCore_Private.WebCore.AV1CodecConfigurationRecord
private typealias AV1ConfigurationProfile = WebCore_Private.WebCore.AV1ConfigurationProfile
private typealias AV1ConfigurationLevel = WebCore_Private.WebCore.AV1ConfigurationLevel
private typealias AV1ConfigurationTier = WebCore_Private.WebCore.AV1ConfigurationTier
private typealias AV1ConfigurationRange = WebCore_Private.WebCore.AV1ConfigurationRange

// MARK: - BitReader

/// WebCore::BitReader: reads MSB-first. `read(0)` does not return 0: the count is decremented
/// before it is tested, so it wraps and the read consumes the rest of the data and fails. Bits
/// shifted past 64 are dropped. A failed read leaves the bits it consumed consumed.
private struct BitReader {
    private let data: ArraySlice<UInt8>
    private var index: Int
    private var currentByte: UInt8 = 0
    private var remainingBits = 0

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func readBit() -> Bool? {
        if remainingBits == 0 {
            if index >= data.endIndex {
                return nil
            }
            currentByte = data[index]
            index += 1
            remainingBits = 8
        }
        let value = currentByte & 0x80 != 0
        remainingBits -= 1
        currentByte = currentByte << 1
        return value
    }

    mutating func read(_ bitCount: Int) -> UInt64? {
        var bits = UInt(bitCount)
        var value: UInt64 = 0
        repeat {
            guard let bit = readBit() else {
                return nil
            }
            value = (value << 1) | (bit ? 1 : 0)
            bits &-= 1
        } while bits != 0
        return value
    }
}

// MARK: - Enum validation

/// isValidEnum<AV1ConfigurationProfile>.
private func isValidProfile(_ value: UInt64) -> Bool {
    value <= 2
}

/// isValidEnum<AV1ConfigurationLevel>: Level_2_0 (0) through Level_7_3 (23), and Level_Maximum (31).
private func isValidLevel(_ value: UInt64) -> Bool {
    value <= 23 || value == 31
}

/// isValidEnum<AV1ConfigurationChromaSubsampling>: subsampling_x, subsampling_y, chroma_sample_position.
private func isValidChromaSubsampling(_ value: UInt8) -> Bool {
    value == 0 || value == 100 || value == 110 || value == 111 || value == 112
}

/// isValidEnum<AV1ConfigurationColorPrimaries>.
private func isValidColorPrimaries(_ value: UInt8) -> Bool {
    value == 1 || value == 2 || (4...12).contains(value) || value == 22
}

/// isValidEnum<AV1ConfigurationTransferCharacteristics>.
private func isValidTransferCharacteristics(_ value: UInt8) -> Bool {
    value == 1 || value == 2 || (4...18).contains(value)
}

/// isValidEnum<AV1ConfigurationMatrixCoefficients>.
private func isValidMatrixCoefficients(_ value: UInt8) -> Bool {
    value <= 2 || (4...14).contains(value)
}

/// isValidEnum<AV1ConfigurationRange>.
private func isValidRange(_ value: UInt8) -> Bool {
    value <= 1
}

// MARK: - Parsed fields

/// The record fields a parse assigns. A nil field is one the parse leaves at its default.
private struct ParsedRecord {
    var profile: AV1ConfigurationProfile?
    var level: AV1ConfigurationLevel?
    var tier: AV1ConfigurationTier?
    var bitDepth: UInt8?
    var monochrome: UInt8?
    var chromaSubsampling: UInt8?
    var colorPrimaries: UInt8?
    var transferCharacteristics: UInt8?
    var matrixCoefficients: UInt8?
    var videoFullRangeFlag: AV1ConfigurationRange?
    var width: UInt32?
    var height: UInt32?
}

extension ParsedRecord {
    func apply(to record: inout AV1CodecConfigurationRecord) {
        if let profile { record.profile = profile }
        if let level { record.level = level }
        if let tier { record.tier = tier }
        if let bitDepth { record.bitDepth = bitDepth }
        if let monochrome { record.monochrome = monochrome }
        if let chromaSubsampling { record.chromaSubsampling = chromaSubsampling }
        if let colorPrimaries { record.colorPrimaries = colorPrimaries }
        if let transferCharacteristics { record.transferCharacteristics = transferCharacteristics }
        if let matrixCoefficients { record.matrixCoefficients = matrixCoefficients }
        if let videoFullRangeFlag { record.videoFullRangeFlag = videoFullRangeFlag }
        if let width { record.width = width }
        if let height { record.height = height }
    }
}

private func store(_ parsed: ParsedRecord, into rawRecord: UnsafeMutableRawPointer) {
    // SAFETY: the caller passes the address of a live AV1CodecConfigurationRecord it constructed
    // and does not touch it until this call returns.
    unsafe parsed.apply(to: &rawRecord.assumingMemoryBound(to: AV1CodecConfigurationRecord.self).pointee)
}

// MARK: - av1C

/// Ref: https://aomediacodec.github.io/av1-isobmff/ Section 2.3: AV1 Codec Configuration Box.
private func parseAV1DecoderConfigurationRecord(_ buffer: ArraySlice<UInt8>) -> ParsedRecord? {
    // AV1CodecConfigurationRecord is at least 4 bytes long.
    if buffer.count < 4 {
        return nil
    }

    var record = ParsedRecord()
    var bitReader = BitReader(buffer)

    // marker f(1) = 1, version f(7) = 1
    guard let marker = bitReader.read(1), marker != 0 else { return nil }
    guard let version = bitReader.read(7), version == 1 else { return nil }

    // seq_profile f(3), seq_level_idx_0 f(5), seq_tier_0 f(1)
    guard let profile = bitReader.read(3), isValidProfile(profile) else { return nil }
    record.profile = AV1ConfigurationProfile(rawValue: UInt8(profile))
    guard let level = bitReader.read(5), isValidLevel(level) else { return nil }
    record.level = AV1ConfigurationLevel(rawValue: UInt8(level))
    guard let tier = bitReader.read(1) else { return nil }
    record.tier = tier != 0 ? .High : .Main

    // high_bitdepth f(1), twelve_bit f(1)
    guard let highBitDepth = bitReader.read(1) else { return nil }
    guard let twelveBit = bitReader.read(1) else { return nil }
    if highBitDepth == 0 && twelveBit != 0 {
        return nil
    }
    record.bitDepth = highBitDepth != 0 ? (twelveBit != 0 ? 12 : 10) : 8

    // monochrome f(1), chroma_subsampling_x f(1), chroma_subsampling_y f(1), chroma_sample_position f(2)
    guard let monochrome = bitReader.read(1) else { return nil }
    record.monochrome = UInt8(monochrome)
    guard let subsamplingX = bitReader.read(1) else { return nil }
    guard let subsamplingY = bitReader.read(1) else { return nil }
    guard let chromaSamplePosition = bitReader.read(2) else { return nil }

    // Digits: subsampling_x, subsampling_y, chroma_sample_position (4:2:0 only, else 0).
    let position = subsamplingX != 0 && subsamplingY != 0 ? chromaSamplePosition : 0
    record.chromaSubsampling = UInt8(subsamplingX * 100 + subsamplingY * 10 + position)

    // The decoder configuration carries no dimensions.
    record.width = 0
    record.height = 0
    return record
}

// MARK: - Sequence header OBU

private func parseSequenceHeaderOBU(_ data: ArraySlice<UInt8>) -> ParsedRecord? {
    var record = ParsedRecord()
    var bitReader = BitReader(data)

    // seq_profile f(3), still_picture f(1), reduced_still_picture_header f(1)
    guard let seqProfile = bitReader.read(3), isValidProfile(seqProfile) else { return nil }
    record.profile = AV1ConfigurationProfile(rawValue: UInt8(seqProfile))
    guard let stillPicture = bitReader.read(1) else { return nil }
    guard let reducedStillPictureHeaderBit = bitReader.read(1) else { return nil }
    let reducedStillPictureHeader = reducedStillPictureHeaderBit != 0
    if reducedStillPictureHeader && stillPicture == 0 {
        return nil
    }

    if reducedStillPictureHeader {
        // seq_level_idx[0] f(5); seq_tier[0] = 0
        guard let level = bitReader.read(5), isValidLevel(level) else { return nil }
        record.level = AV1ConfigurationLevel(rawValue: UInt8(level))
        record.tier = .Main
    } else {
        var decoderModelInfoPresentFlag = false
        var bufferDelayLengthMinus1: UInt64 = 0

        // timing_info_present_flag f(1)
        guard let timingInfoPresentFlag = bitReader.read(1) else { return nil }
        if timingInfoPresentFlag != 0 {
            // timing_info(): num_units_in_display_tick f(32), time_scale f(32), equal_picture_interval f(1)
            guard bitReader.read(32) != nil, bitReader.read(32) != nil else { return nil }
            guard let equalPictureInterval = bitReader.read(1) else { return nil }
            if equalPictureInterval != 0 {
                // num_ticks_per_picture_minus_1 uvlc(): stops at 32 leading zeros without
                // consuming the terminating bit.
                var leadingZeros = 0
                while true {
                    guard let bit = bitReader.read(1) else { return nil }
                    if bit != 0 {
                        break
                    }
                    leadingZeros += 1
                    if leadingZeros >= 32 {
                        break
                    }
                }
                if leadingZeros < 32 && leadingZeros > 0 {
                    guard bitReader.read(leadingZeros) != nil else { return nil }
                }
            }

            // decoder_model_info_present_flag f(1)
            guard let decoderModelInfoPresent = bitReader.read(1) else { return nil }
            decoderModelInfoPresentFlag = decoderModelInfoPresent != 0
            if decoderModelInfoPresentFlag {
                // decoder_model_info(): buffer_delay_length_minus_1 f(5), num_units_in_decoding_tick f(32),
                // buffer_removal_time_length_minus_1 f(5), frame_presentation_time_length_minus_1 f(5)
                guard let bufferDelayLength = bitReader.read(5) else { return nil }
                bufferDelayLengthMinus1 = bufferDelayLength
                guard bitReader.read(32) != nil, bitReader.read(5) != nil, bitReader.read(5) != nil else { return nil }
            }
        }

        // initial_display_delay_present_flag f(1), operating_points_cnt_minus_1 f(5)
        guard let initialDisplayDelayPresentFlag = bitReader.read(1) else { return nil }
        guard let operatingPointsCntMinus1 = bitReader.read(5) else { return nil }

        for i in 0...operatingPointsCntMinus1 {
            // operating_point_idc[i] f(12), seq_level_idx[i] f(5)
            guard bitReader.read(12) != nil else { return nil }
            guard let seqLevelIdx = bitReader.read(5) else { return nil }
            // The first operating point's level and tier are the record's.
            if i == 0 {
                if !isValidLevel(seqLevelIdx) {
                    return nil
                }
                record.level = AV1ConfigurationLevel(rawValue: UInt8(seqLevelIdx))
            }

            // seq_tier[i] f(1), present only above level 3.3
            if seqLevelIdx > 7 {
                guard let tier = bitReader.read(1) else { return nil }
                if i == 0 {
                    record.tier = tier != 0 ? .High : .Main
                }
            } else if i == 0 {
                record.tier = .Main
            }

            if decoderModelInfoPresentFlag {
                // decoder_model_present_for_this_op[i] f(1)
                guard let decoderModelPresentForThisOp = bitReader.read(1) else { return nil }
                if decoderModelPresentForThisOp != 0 {
                    // operating_parameters_info(i): decoder_buffer_delay f(n), encoder_buffer_delay f(n),
                    // low_delay_mode_flag f(1), with n = buffer_delay_length_minus_1 + 1
                    let n = Int(bufferDelayLengthMinus1) + 1
                    guard bitReader.read(n) != nil, bitReader.read(n) != nil, bitReader.read(1) != nil else { return nil }
                }
            }

            if initialDisplayDelayPresentFlag != 0 {
                // initial_display_delay_present_for_this_op[i] f(1), initial_display_delay_minus_1[i] f(4)
                guard let initialDisplayDelayPresentForThisOp = bitReader.read(1) else { return nil }
                if initialDisplayDelayPresentForThisOp != 0 {
                    guard bitReader.read(4) != nil else { return nil }
                }
            }
        }
    }

    // frame_width_bits_minus_1 f(4), frame_height_bits_minus_1 f(4),
    // max_frame_width_minus_1 f(n), max_frame_height_minus_1 f(n)
    guard let frameWidthBitsMinus1 = bitReader.read(4) else { return nil }
    guard let frameHeightBitsMinus1 = bitReader.read(4) else { return nil }
    guard let maxFrameWidthMinus1 = bitReader.read(Int(frameWidthBitsMinus1) + 1) else { return nil }
    record.width = UInt32(maxFrameWidthMinus1 + 1)
    guard let maxFrameHeightMinus1 = bitReader.read(Int(frameHeightBitsMinus1) + 1) else { return nil }
    record.height = UInt32(maxFrameHeightMinus1 + 1)

    if !reducedStillPictureHeader {
        // frame_id_numbers_present_flag f(1)
        guard let frameIdNumbersPresentFlag = bitReader.read(1) else { return nil }
        if frameIdNumbersPresentFlag != 0 {
            // delta_frame_id_length_minus_2 f(4), additional_frame_id_length_minus_1 f(3)
            guard bitReader.read(4) != nil, bitReader.read(3) != nil else { return nil }
        }
    }

    // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter f(1)
    guard bitReader.read(1) != nil, bitReader.read(1) != nil, bitReader.read(1) != nil else { return nil }

    if !reducedStillPictureHeader {
        // enable_interintra_compound, enable_masked_compound, enable_warped_motion, enable_dual_filter f(1)
        guard bitReader.read(1) != nil, bitReader.read(1) != nil, bitReader.read(1) != nil, bitReader.read(1) != nil else { return nil }

        // enable_order_hint f(1); if set, enable_jnt_comp f(1), enable_ref_frame_mvs f(1)
        guard let enableOrderHint = bitReader.read(1) else { return nil }
        if enableOrderHint != 0 {
            guard bitReader.read(1) != nil, bitReader.read(1) != nil else { return nil }
        }

        // seq_choose_screen_content_tools f(1), seq_force_screen_content_tools f(1)
        guard let seqChooseScreenContentTools = bitReader.read(1) else { return nil }
        var seqForceScreenContentTools: UInt64 = 2 // SELECT_SCREEN_CONTENT_TOOLS
        if seqChooseScreenContentTools == 0 {
            guard let force = bitReader.read(1) else { return nil }
            seqForceScreenContentTools = force
        }

        if seqForceScreenContentTools > 0 {
            // seq_choose_integer_mv f(1), seq_force_integer_mv f(1)
            guard let seqChooseIntegerMv = bitReader.read(1) else { return nil }
            if seqChooseIntegerMv == 0 {
                guard bitReader.read(1) != nil else { return nil }
            }
        }

        if enableOrderHint != 0 {
            // order_hint_bits_minus_1 f(3)
            guard bitReader.read(3) != nil else { return nil }
        }
    }

    // enable_superres, enable_cdef, enable_restoration f(1)
    guard bitReader.read(1) != nil, bitReader.read(1) != nil, bitReader.read(1) != nil else { return nil }

    // color_config(): high_bitdepth f(1), twelve_bit f(1)
    guard let highBitdepth = bitReader.read(1) else { return nil }
    var bitDepth: UInt8?
    if seqProfile == 2 && highBitdepth != 0 {
        guard let twelveBit = bitReader.read(1) else { return nil }
        bitDepth = twelveBit != 0 ? 12 : 10
    } else if seqProfile <= 2 {
        bitDepth = highBitdepth != 0 ? 10 : 8
    }
    record.bitDepth = bitDepth

    // mono_chrome f(1)
    var monochrome: UInt8 = 0
    if seqProfile != 1 {
        guard let bit = bitReader.read(1) else { return nil }
        monochrome = UInt8(bit)
    }
    record.monochrome = monochrome

    // color_description_present_flag f(1); color_primaries, transfer_characteristics, matrix_coefficients f(8)
    guard let colorDescriptionPresentFlag = bitReader.read(1) else { return nil }
    var colorPrimaries: UInt8 = 2 // Unspecified
    var transferCharacteristics: UInt8 = 2 // Unspecified
    var matrixCoefficients: UInt8 = 2 // Unspecified
    if colorDescriptionPresentFlag != 0 {
        guard let primaries = bitReader.read(8) else { return nil }
        colorPrimaries = UInt8(primaries)
        guard let transfer = bitReader.read(8) else { return nil }
        transferCharacteristics = UInt8(transfer)
        guard let matrix = bitReader.read(8) else { return nil }
        matrixCoefficients = UInt8(matrix)
    }
    record.colorPrimaries = colorPrimaries
    record.transferCharacteristics = transferCharacteristics
    record.matrixCoefficients = matrixCoefficients

    var colorRange = false
    var subsamplingX: UInt8 = 1
    var subsamplingY: UInt8 = 1
    var chromaSamplePosition: UInt8 = 0 // CSP_UNKNOWN

    // CP_BT_709, TC_SRGB, MC_IDENTITY
    let isSRGBIdentity = colorPrimaries == 1 && transferCharacteristics == 13 && matrixCoefficients == 0

    if monochrome != 0 {
        // color_range f(1)
        guard let range = bitReader.read(1) else { return nil }
        colorRange = range != 0
    } else if isSRGBIdentity {
        colorRange = true
        subsamplingX = 0
        subsamplingY = 0
    } else {
        // color_range f(1)
        guard let range = bitReader.read(1) else { return nil }
        colorRange = range != 0

        if seqProfile == 0 {
            subsamplingX = 1
            subsamplingY = 1
        } else if seqProfile == 1 {
            subsamplingX = 0
            subsamplingY = 0
        } else if bitDepth == 12 {
            // subsampling_x f(1), subsampling_y f(1)
            guard let x = bitReader.read(1) else { return nil }
            subsamplingX = UInt8(x)
            if subsamplingX != 0 {
                guard let y = bitReader.read(1) else { return nil }
                subsamplingY = UInt8(y)
            } else {
                subsamplingY = 0
            }
        } else {
            subsamplingX = 1
            subsamplingY = 0
        }

        if subsamplingX != 0 && subsamplingY != 0 {
            // chroma_sample_position f(2)
            guard let position = bitReader.read(2) else { return nil }
            chromaSamplePosition = UInt8(position)
        }
    }

    record.videoFullRangeFlag = colorRange ? .FullRange : .VideoRange

    // Digits: subsampling_x, subsampling_y, chroma_sample_position (4:2:0 only, else 0).
    var chromaSubsampling = subsamplingX * 100 + subsamplingY * 10
    if subsamplingX != 0 && subsamplingY != 0 {
        chromaSubsampling += chromaSamplePosition
    }
    record.chromaSubsampling = chromaSubsampling
    return record
}

// MARK: - OBU framing

/// leb128(), limited to 8 bytes. Returns 0 when the data runs out or the value reaches
/// UINT32_MAX, having advanced `index` past the bytes it read; a zero size is indistinguishable
/// from a failure.
private func readULEBSize(_ data: [UInt8], _ index: inout Int) -> Int {
    var value: UInt = 0
    for cptr in 0..<8 {
        if index >= data.count {
            return 0
        }
        let dataByte = data[index]
        index += 1
        value |= UInt(dataByte & 0x7f) << (7 * cptr)
        if value >= UInt(UInt32.max) {
            return 0
        }
        if dataByte & 0x80 == 0 {
            break
        }
    }
    return Int(value)
}

/// Finds the first sequence header OBU. Returns the range of the whole OBU and of its payload.
private func getSequenceHeaderOBU(_ data: [UInt8]) -> (fullObu: Range<Int>, obuData: Range<Int>)? {
    var index = 0
    while true {
        if index >= data.count {
            return nil
        }

        let startIndex = index
        let value = data[index]
        index += 1
        if value >> 7 != 0 {
            return nil
        }
        let headerType = value >> 3
        // obu_has_size_field
        if value & 0x02 == 0 {
            return nil
        }
        // obu_extension_flag
        if value & 0x04 != 0 {
            index += 1
        }

        let payloadSize = readULEBSize(data, &index)
        if index + payloadSize > data.count {
            return nil
        }

        if headerType == 1 {
            return (startIndex..<(payloadSize + index), index..<(index + payloadSize))
        }

        index += payloadSize
    }
}

// MARK: - Codecs parameter string

/// parseInteger<uint8_t>: optional leading and trailing whitespace (space, \t, \n, \v, \f, \r),
/// an optional '+', then one or more decimal digits. Anything else, or a value above 255, fails.
private func parseUInt8(_ characters: ArraySlice<UInt16>) -> UInt8? {
    func isWhitespace(_ character: UInt16) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }
    func isDigit(_ character: UInt16) -> Bool {
        (0x30...0x39).contains(character)
    }

    var rest = characters.drop(while: isWhitespace)
    if rest.first == 0x2B {
        rest = rest.dropFirst()
    }
    let digits = rest.prefix(while: isDigit)
    if digits.isEmpty || !rest.dropFirst(digits.count).allSatisfy(isWhitespace) {
        return nil
    }

    var value = 0
    for digit in digits {
        value = value * 10 + Int(digit - 0x30)
        if value > Int(UInt8.max) {
            return nil
        }
    }
    return UInt8(value)
}

/// Ref: https://aomediacodec.github.io/av1-isobmff/#codecsparam Section 5: Codecs Parameter String.
/// <4CC>.<profile>.<level><tier>.<bitDepth>[.<monochrome>[.<chromaSubsampling>[.<colorPrimaries>
/// [.<transferCharacteristics>[.<matrixCoefficients>.<videoFullRangeFlag>]]]]]
private func parseAV1CodecParameters(_ characters: [UInt16]) -> ParsedRecord? {
    // StringView::split: empty elements are skipped, so "av01..0" has two elements.
    let elements = characters.split(separator: 0x2E)
    guard elements.count >= 4, elements[0].elementsEqual("av01".utf16) else { return nil }

    var record = ParsedRecord()

    guard let profile = parseUInt8(elements[1]), isValidProfile(UInt64(profile)) else { return nil }
    record.profile = AV1ConfigurationProfile(rawValue: profile)

    // The last character is the tier; the ones before it are the level.
    let levelTier = elements[2]
    if levelTier.count < 3 {
        return nil
    }
    guard let level = parseUInt8(levelTier.dropLast()), isValidLevel(UInt64(level)) else { return nil }
    record.level = AV1ConfigurationLevel(rawValue: level)
    switch levelTier.last {
    case 0x4D?: // 'M'
        record.tier = .Main
    case 0x48?: // 'H'
        record.tier = .High
    default:
        return nil
    }

    guard let bitDepth = parseUInt8(elements[3]), bitDepth <= 12 else { return nil }
    record.bitDepth = bitDepth

    // An omitted optional field keeps the record default, which is the value the specification assumes.
    if elements.count == 4 {
        return record
    }
    guard let monochrome = parseUInt8(elements[4]), monochrome <= 1 else { return nil }
    record.monochrome = monochrome

    if elements.count == 5 {
        return record
    }
    guard let chromaSubsampling = parseUInt8(elements[5]), isValidChromaSubsampling(chromaSubsampling) else { return nil }
    record.chromaSubsampling = chromaSubsampling

    if elements.count == 6 {
        return record
    }
    guard let colorPrimaries = parseUInt8(elements[6]), isValidColorPrimaries(colorPrimaries) else { return nil }
    record.colorPrimaries = colorPrimaries

    if elements.count == 7 {
        return record
    }
    guard let transferCharacteristics = parseUInt8(elements[7]), isValidTransferCharacteristics(transferCharacteristics) else { return nil }
    record.transferCharacteristics = transferCharacteristics

    if elements.count == 8 {
        return record
    }
    guard let matrixCoefficients = parseUInt8(elements[8]), isValidMatrixCoefficients(matrixCoefficients) else { return nil }
    record.matrixCoefficients = matrixCoefficients

    // videoFullRangeFlag must follow matrixCoefficients and ends the string.
    guard elements.count == 10, let range = parseUInt8(elements[9]), isValidRange(range) else { return nil }
    record.videoFullRangeFlag = AV1ConfigurationRange(rawValue: range)
    return record
}

// MARK: - Validation

/// The record fields the validators read.
private struct RecordFields {
    var profile: UInt8
    var level: AV1ConfigurationLevel
    var tier: UInt8
    var bitDepth: UInt8
    var monochrome: UInt8
    var chromaSubsampling: UInt8

    init(_ record: borrowing AV1CodecConfigurationRecord) {
        profile = record.profile.rawValue
        level = record.level
        tier = record.tier.rawValue
        bitDepth = record.bitDepth
        monochrome = record.monochrome
        chromaSubsampling = record.chromaSubsampling
    }
}

private func loadFields(from rawRecord: UnsafeRawPointer) -> RecordFields {
    // SAFETY: the caller passes the address of a live AV1CodecConfigurationRecord and does not
    // modify it until this call returns.
    unsafe RecordFields(rawRecord.assumingMemoryBound(to: AV1CodecConfigurationRecord.self).pointee)
}

/// Ref: https://aomediacodec.github.io/av1-spec/av1-spec.pdf
private func validateAV1ConfigurationRecord(_ record: RecordFields) -> Bool {
    // 6.4.1. General sequence header OBU semantics
    let chromaSubsampling = record.chromaSubsampling
    if !isValidChromaSubsampling(chromaSubsampling) {
        return false
    }
    let is444 = chromaSubsampling == 0
    let is420 = chromaSubsampling == 110 || chromaSubsampling == 111 || chromaSubsampling == 112
    let is8Or10Bit = record.bitDepth == 8 || record.bitDepth == 10

    switch record.profile {
    case AV1ConfigurationProfile.Main.rawValue:
        if !is8Or10Bit || !is420 {
            return false
        }
    case AV1ConfigurationProfile.High.rawValue:
        if !is8Or10Bit || record.monochrome != 0 || !is444 {
            return false
        }
    case AV1ConfigurationProfile.Professional.rawValue:
        if is8Or10Bit ? !is444 : record.bitDepth != 12 {
            return false
        }
    default:
        break
    }

    // 6.4.2. Color config semantics: monochrome requires 4:2:0 with CSP_UNKNOWN.
    return record.monochrome == 0 || chromaSubsampling == 110
}

private struct PerLevelConstraints {
    var maxPicSize: UInt32
    var maxWidth: UInt32
    var maxHeight: UInt32
    var maxFramerate: Double
    var mainMaxBitrate: UInt32
    var highMaxBitrate: UInt32

    init(_ maxPicSize: UInt32, _ maxWidth: UInt32, _ maxHeight: UInt32, _ maxFramerate: Double, _ mainMaxBitrate: UInt32, _ highMaxBitrate: UInt32) {
        self.maxPicSize = maxPicSize
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFramerate = maxFramerate
        self.mainMaxBitrate = mainMaxBitrate
        self.highMaxBitrate = highMaxBitrate
    }
}

/// Derived from "AV1 Bitstream & Decoding Process Specification", Version 1.0.0 with Errata 1,
/// Annex A: Profiles and levels. A level without an entry fails validation.
private func perLevelConstraints(_ level: AV1ConfigurationLevel) -> PerLevelConstraints? {
    switch level {
    case .Level_2_0: PerLevelConstraints(147456, 2048, 1152, 30, 1572864, 0)
    case .Level_2_1: PerLevelConstraints(278784, 2816, 1584, 30, 3145728, 0)
    case .Level_3_0: PerLevelConstraints(665856, 4352, 2448, 30, 6291456, 0)
    case .Level_3_1: PerLevelConstraints(1065024, 5504, 3096, 30, 10485760, 0)
    case .Level_4_0: PerLevelConstraints(2359296, 6144, 3456, 30, 12582912, 31457280)
    case .Level_4_1: PerLevelConstraints(2359296, 6144, 3456, 60, 20971520, 52428800)
    case .Level_5_0: PerLevelConstraints(8912896, 8192, 4352, 30, 31457280, 104857600)
    case .Level_5_1: PerLevelConstraints(8912896, 8192, 4352, 60, 41943040, 167772160)
    case .Level_5_2: PerLevelConstraints(8912896, 8192, 4352, 120, 62914560, 251658240)
    case .Level_5_3: PerLevelConstraints(8912896, 8192, 4352, 120, 62914560, 251658240)
    case .Level_6_0: PerLevelConstraints(35651584, 16384, 8704, 30, 62914560, 251658240)
    case .Level_6_1: PerLevelConstraints(35651584, 16384, 8704, 60, 104857600, 503316480)
    case .Level_6_2: PerLevelConstraints(35651584, 16384, 8704, 120, 167772160, 838860800)
    case .Level_6_3: PerLevelConstraints(35651584, 16384, 8704, 120, 167772160, 838860800)
    default: nil
    }
}

private func validateAV1PerLevelConstraints(_ record: RecordFields, width: UInt32, height: UInt32, bitrate: UInt64, framerate: Double) -> Bool {
    guard let constraints = perLevelConstraints(record.level) else { return false }
    let maxBitrate = record.tier == AV1ConfigurationTier.Main.rawValue ? constraints.mainMaxBitrate : constraints.highMaxBitrate
    // The picture size is computed modulo 2^32; a NaN framerate fails.
    return width <= constraints.maxWidth
        && height <= constraints.maxHeight
        && width &* height <= constraints.maxPicSize
        && framerate <= constraints.maxFramerate
        && bitrate <= UInt64(maxBitrate)
}

// MARK: - Boundary

private func copyBytes(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> [UInt8] {
    // SAFETY: the caller passes `count` readable bytes at `bytes`, which is null only when
    // `count` is 0; they are copied out before this call returns.
    unsafe bytes.map { unsafe Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
}

@_cdecl("WebCoreAV1ParseDecoderConfigurationRecord")
internal func webCoreAV1ParseDecoderConfigurationRecord(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ rawRecord: UnsafeMutableRawPointer) -> Bool {
    let data = unsafe copyBytes(bytes, count)
    guard let parsed = parseAV1DecoderConfigurationRecord(data[...]) else {
        return false
    }
    unsafe store(parsed, into: rawRecord)
    return true
}

@_cdecl("WebCoreAV1ParseSequenceHeader")
internal func webCoreAV1ParseSequenceHeader(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ rawRecord: UnsafeMutableRawPointer, _ obuOffsetAndSize: UnsafeMutablePointer<Int>) -> Bool {
    let data = unsafe copyBytes(bytes, count)
    guard let obu = getSequenceHeaderOBU(data), let parsed = parseSequenceHeaderOBU(data[obu.obuData]) else {
        return false
    }
    unsafe store(parsed, into: rawRecord)
    // SAFETY: the caller passes room for two Ints at `obuOffsetAndSize`.
    unsafe (obuOffsetAndSize[0], obuOffsetAndSize[1]) = (obu.fullObu.lowerBound, obu.fullObu.count)
    return true
}

/// Latin-1 characters widen to the UTF-16 code units of the same code points.
private func copyCharacters(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool) -> [UInt16] {
    // SAFETY: the caller passes `length` Latin-1 bytes if `is8Bit`, else `length` UTF-16 code units,
    // at `characters`, which is null only when `length` is 0; they are copied out before this call returns.
    unsafe characters.map { base in
        if is8Bit {
            return unsafe UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: length).map(UInt16.init)
        }
        return unsafe Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt16.self), count: length))
    } ?? []
}

@_cdecl("WebCoreAV1ParseCodecParameters")
internal func webCoreAV1ParseCodecParameters(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool, _ rawRecord: UnsafeMutableRawPointer) -> Bool {
    let string = unsafe copyCharacters(characters, length, is8Bit)
    guard let parsed = parseAV1CodecParameters(string) else {
        return false
    }
    unsafe store(parsed, into: rawRecord)
    return true
}

@_cdecl("WebCoreAV1ValidateConfigurationRecord")
internal func webCoreAV1ValidateConfigurationRecord(_ rawRecord: UnsafeRawPointer) -> Bool {
    validateAV1ConfigurationRecord(unsafe loadFields(from: rawRecord))
}

@_cdecl("WebCoreAV1ValidatePerLevelConstraints")
internal func webCoreAV1ValidatePerLevelConstraints(_ rawRecord: UnsafeRawPointer, _ width: UInt32, _ height: UInt32, _ bitrate: UInt64, _ framerate: Double) -> Bool {
    validateAV1PerLevelConstraints(unsafe loadFields(from: rawRecord), width: width, height: height, bitrate: bitrate, framerate: framerate)
}

#endif // ENABLE_AV1_UTILITIES_SWIFT
