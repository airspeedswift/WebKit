/*
 * Copyright (C) 2005, 2006, 2007, 2008, 2009, 2010 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// The two character-code key tables of KeyEventCocoa.mm, in Swift.
//
// The tables were generated mechanically from the C++ and are checked against
// it by a differential over all 65536 values of `unichar`; see the wk.swift
// store binding key_table_port_diff.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_KEY_EVENT_TABLES_SWIFT to swiftc for a truthy ENABLE() macro, so the
// Swift spelling of the same gate is a bare identifier.

#if ENABLE_KEY_EVENT_TABLES_SWIFT

/// The largest number of UTF-16 code units either table can produce.
///
/// `Unidentified`, the longest, is 12. KeyEventCocoa.mm static_asserts the
/// The `key` attribute value for `charCode`, or nil when the key is the
/// character itself.
///
/// https://w3c.github.io/uievents-key/
private func keyNameForCharCode(_ charCode: Swift.UInt16) -> Swift.StaticString? {
    switch charCode {
    case 0xF700: // NSUpArrowFunctionKey
        return "ArrowUp"
    case 0xF701: // NSDownArrowFunctionKey
        return "ArrowDown"
    case 0xF702: // NSLeftArrowFunctionKey
        return "ArrowLeft"
    case 0xF703: // NSRightArrowFunctionKey
        return "ArrowRight"
    case 0xF704: // NSF1FunctionKey
        return "F1"
    case 0xF705: // NSF2FunctionKey
        return "F2"
    case 0xF706: // NSF3FunctionKey
        return "F3"
    case 0xF707: // NSF4FunctionKey
        return "F4"
    case 0xF708: // NSF5FunctionKey
        return "F5"
    case 0xF709: // NSF6FunctionKey
        return "F6"
    case 0xF70A: // NSF7FunctionKey
        return "F7"
    case 0xF70B: // NSF8FunctionKey
        return "F8"
    case 0xF70C: // NSF9FunctionKey
        return "F9"
    case 0xF70D: // NSF10FunctionKey
        return "F10"
    case 0xF70E: // NSF11FunctionKey
        return "F11"
    case 0xF70F: // NSF12FunctionKey
        return "F12"
    case 0xF710: // NSF13FunctionKey
        return "F13"
    case 0xF711: // NSF14FunctionKey
        return "F14"
    case 0xF712: // NSF15FunctionKey
        return "F15"
    case 0xF713: // NSF16FunctionKey
        return "F16"
    case 0xF714: // NSF17FunctionKey
        return "F17"
    case 0xF715: // NSF18FunctionKey
        return "F18"
    case 0xF716: // NSF19FunctionKey
        return "F19"
    case 0xF717: // NSF20FunctionKey
        return "F20"
    case 0xF718: // NSF21FunctionKey
        return "F21"
    case 0xF719: // NSF22FunctionKey
        return "F22"
    case 0xF71A: // NSF23FunctionKey
        return "F23"
    case 0xF71B: // NSF24FunctionKey
        return "F24"
    case 0xF71C: // NSF25FunctionKey
        return "F25"
    case 0xF71D: // NSF26FunctionKey
        return "F26"
    case 0xF71E: // NSF27FunctionKey
        return "F27"
    case 0xF71F: // NSF28FunctionKey
        return "F28"
    case 0xF720: // NSF29FunctionKey
        return "F29"
    case 0xF721: // NSF30FunctionKey
        return "F30"
    case 0xF722: // NSF31FunctionKey
        return "F31"
    case 0xF723: // NSF32FunctionKey
        return "F32"
    case 0xF724: // NSF33FunctionKey
        return "F33"
    case 0xF725: // NSF34FunctionKey
        return "F34"
    case 0xF726: // NSF35FunctionKey
        return "F35"
    case 0xF727: // NSInsertFunctionKey
        return "Insert"
    case 0xF728: // NSDeleteFunctionKey
        return "Delete"
    case 0xF729: // NSHomeFunctionKey
        return "Home"
    case 0xF72B: // NSEndFunctionKey
        return "End"
    case 0xF72C: // NSPageUpFunctionKey
        return "PageUp"
    case 0xF72D: // NSPageDownFunctionKey
        return "PageDown"
    case 0xF72E: // NSPrintScreenFunctionKey
        return "PrintScreen"
    case 0xF72F: // NSScrollLockFunctionKey
        return "ScrollLock"
    case 0xF730: // NSPauseFunctionKey
        return "Pause"
    case 0xF735: // NSMenuFunctionKey
        return "ContextMenu"
    case 0xF738: // NSPrintFunctionKey
        return "Print"
    case 0xF739: // NSClearLineFunctionKey
        return "Clear"
    case 0xF741: // NSSelectFunctionKey
        return "Select"
    case 0xF742: // NSExecuteFunctionKey
        return "Execute"
    case 0xF743: // NSUndoFunctionKey
        return "Undo"
    case 0xF744: // NSRedoFunctionKey
        return "Redo"
    case 0xF745: // NSFindFunctionKey
        return "Find"
    case 0xF746: // NSHelpFunctionKey
        return "Help"
    case 0xF747: // NSModeSwitchFunctionKey
        return "ModeChange"
    case 0x0003, // NSEnterCharacter
        0x000A, // NSNewlineCharacter
        0x000D: // NSCarriageReturnCharacter
        return "Enter"
    case 0x007F, // NSDeleteCharacter
        0x0008: // NSBackspaceCharacter
        return "Backspace"
    case 0x0019, // NSBackTabCharacter
        0x0009: // NSTabCharacter
        return "Tab"
    case 0x001B:
        return "Escape"
    case 0x000C, // NSFormFeedCharacter
        0x2029, // NSParagraphSeparatorCharacter
        0x2028, // NSLineSeparatorCharacter
        0xF72A, // NSBeginFunctionKey
        0xF731, // NSSysReqFunctionKey
        0xF732, // NSBreakFunctionKey
        0xF733, // NSResetFunctionKey
        0xF734, // NSStopFunctionKey
        0xF736, // NSUserFunctionKey
        0xF737, // NSSystemFunctionKey
        0xF73A, // NSClearDisplayFunctionKey
        0xF73B, // NSInsertLineFunctionKey
        0xF73C, // NSDeleteLineFunctionKey
        0xF73D, // NSInsertCharFunctionKey
        0xF73E, // NSDeleteCharFunctionKey
        0xF73F, // NSPrevFunctionKey
        0xF740: // NSNextFunctionKey
        return "Unidentified"
    default:
        return nil
    }
}

/// The legacy `keyIdentifier` value for `charCode`, or nil when it is the
/// character's code point spelled `U+XXXX`.
///
/// Each identifier listed in the DOM spec is listed in KeyEventCocoa.mm; the
/// many that do not appear on standard Macintosh keyboards, or that are on a
/// key with no corresponding character, are commented out there and are
/// deliberately absent here.
private func keyIdentifierNameForCharCode(_ charCode: Swift.UInt16) -> Swift.StaticString? {
    switch charCode {
    case 0xF735: // NSMenuFunctionKey
        return "Alt"
    case 0xF739: // NSClearLineFunctionKey
        return "Clear"
    case 0xF701: // NSDownArrowFunctionKey
        return "Down"
    case 0xF72B: // NSEndFunctionKey
        return "End"
    case 0x0003, // NSEnterCharacter
        0x000A, // NSNewlineCharacter
        0x000D: // NSCarriageReturnCharacter
        return "Enter"
    case 0xF742: // NSExecuteFunctionKey
        return "Execute"
    case 0xF704: // NSF1FunctionKey
        return "F1"
    case 0xF705: // NSF2FunctionKey
        return "F2"
    case 0xF706: // NSF3FunctionKey
        return "F3"
    case 0xF707: // NSF4FunctionKey
        return "F4"
    case 0xF708: // NSF5FunctionKey
        return "F5"
    case 0xF709: // NSF6FunctionKey
        return "F6"
    case 0xF70A: // NSF7FunctionKey
        return "F7"
    case 0xF70B: // NSF8FunctionKey
        return "F8"
    case 0xF70C: // NSF9FunctionKey
        return "F9"
    case 0xF70D: // NSF10FunctionKey
        return "F10"
    case 0xF70E: // NSF11FunctionKey
        return "F11"
    case 0xF70F: // NSF12FunctionKey
        return "F12"
    case 0xF710: // NSF13FunctionKey
        return "F13"
    case 0xF711: // NSF14FunctionKey
        return "F14"
    case 0xF712: // NSF15FunctionKey
        return "F15"
    case 0xF713: // NSF16FunctionKey
        return "F16"
    case 0xF714: // NSF17FunctionKey
        return "F17"
    case 0xF715: // NSF18FunctionKey
        return "F18"
    case 0xF716: // NSF19FunctionKey
        return "F19"
    case 0xF717: // NSF20FunctionKey
        return "F20"
    case 0xF718: // NSF21FunctionKey
        return "F21"
    case 0xF719: // NSF22FunctionKey
        return "F22"
    case 0xF71A: // NSF23FunctionKey
        return "F23"
    case 0xF71B: // NSF24FunctionKey
        return "F24"
    case 0xF745: // NSFindFunctionKey
        return "Find"
    case 0xF746: // NSHelpFunctionKey
        return "Help"
    case 0xF729: // NSHomeFunctionKey
        return "Home"
    case 0xF727: // NSInsertFunctionKey
        return "Insert"
    case 0xF702: // NSLeftArrowFunctionKey
        return "Left"
    case 0xF747: // NSModeSwitchFunctionKey
        return "ModeChange"
    case 0xF72D: // NSPageDownFunctionKey
        return "PageDown"
    case 0xF72C: // NSPageUpFunctionKey
        return "PageUp"
    case 0xF730: // NSPauseFunctionKey
        return "Pause"
    case 0xF72E: // NSPrintScreenFunctionKey
        return "PrintScreen"
    case 0xF703: // NSRightArrowFunctionKey
        return "Right"
    case 0xF72F: // NSScrollLockFunctionKey
        return "Scroll"
    case 0xF741: // NSSelectFunctionKey
        return "Select"
    case 0xF734: // NSStopFunctionKey
        return "Stop"
    case 0xF700: // NSUpArrowFunctionKey
        return "Up"
    case 0xF743: // NSUndoFunctionKey
        return "Undo"
    case 0xF71C: // NSF25FunctionKey
        return "F25"
    case 0xF71D: // NSF26FunctionKey
        return "F26"
    case 0xF71E: // NSF27FunctionKey
        return "F27"
    case 0xF71F: // NSF28FunctionKey
        return "F28"
    case 0xF720: // NSF29FunctionKey
        return "F29"
    case 0xF721: // NSF30FunctionKey
        return "F30"
    case 0xF722: // NSF31FunctionKey
        return "F31"
    case 0xF723: // NSF32FunctionKey
        return "F32"
    case 0xF724: // NSF33FunctionKey
        return "F33"
    case 0xF725: // NSF34FunctionKey
        return "F34"
    case 0xF726: // NSF35FunctionKey
        return "F35"
    case 0x007F: // NSDeleteCharacter
        return "U+0008"
    case 0xF728: // NSDeleteFunctionKey
        return "U+007F"
    case 0x0019: // NSBackTabCharacter
        return "U+0009"
    case 0xF72A, // NSBeginFunctionKey
        0xF732, // NSBreakFunctionKey
        0xF73A, // NSClearDisplayFunctionKey
        0xF73E, // NSDeleteCharFunctionKey
        0xF73C, // NSDeleteLineFunctionKey
        0xF73D, // NSInsertCharFunctionKey
        0xF73B, // NSInsertLineFunctionKey
        0xF740, // NSNextFunctionKey
        0xF73F, // NSPrevFunctionKey
        0xF738, // NSPrintFunctionKey
        0xF744, // NSRedoFunctionKey
        0xF733, // NSResetFunctionKey
        0xF731, // NSSysReqFunctionKey
        0xF737, // NSSystemFunctionKey
        0xF736: // NSUserFunctionKey
        // FIXME: We should use something other than the vendor-area
        // Unicode values for the keys above. For now they fall through.
        fallthrough
    default:
        return nil
    }
}

/// Writes the `key` attribute value for `charCode` into `buffer` as UTF-16 and
/// returns how many code units it wrote.
///
/// The C++ caller turns that into a `WTF::String`. UTF-16 rather than UTF-8
/// because the fallback result is the code unit itself, which may be an
/// unpaired surrogate -- not representable in UTF-8, and not representable as a
/// `Swift.String` either. `buffer` must have room for
/// The DOM `key` name for `charCode`, or null when the tables do not name it.
///
/// Returns a pointer into static storage, valid for the process lifetime, rather than a
/// string: WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO and declares no
/// SWIFT_OBJC_INTERFACE_HEADER_NAME, so C++ cannot name a Swift declaration and the only
/// boundary available is `@_cdecl`, which cannot carry a `Swift.String`.
///
/// The caller keeps the fallback. That is not tidiness: `keyForCharCode`'s fallback is the
/// input code unit itself, which may be an unpaired surrogate, and no `Swift.String` can
/// hold one -- `Unicode.Scalar(0xD800)` is nil -- while `WTF::String` holds it fine. Leaving
/// both fallbacks in C++ keeps the case Swift cannot represent on the side that can.
@_cdecl("WebCoreKeyNameForCharCode")
public func webCoreKeyNameForCharCode(_ charCode: Swift.UInt16) -> Swift.UnsafePointer<Swift.CChar>? {
    guard let name = keyNameForCharCode(charCode) else {
        return nil
    }
    // The one unsafe operation in this file: a StaticString's utf8Start addresses static
    // storage, so the pointer outlives every caller and no lifetime is being asserted.
    return unsafe Swift.UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: Swift.CChar.self)
}

/// The legacy `keyIdentifier` name for `charCode`, or null when the tables do not name it.
///
/// See `webCoreKeyNameForCharCode`. The caller formats the `U+XXXX` fallback, as it did
/// before this table moved to Swift.
@_cdecl("WebCoreKeyIdentifierNameForCharCode")
public func webCoreKeyIdentifierNameForCharCode(_ charCode: Swift.UInt16) -> Swift.UnsafePointer<Swift.CChar>? {
    guard let name = keyIdentifierNameForCharCode(charCode) else {
        return nil
    }
    return unsafe Swift.UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: Swift.CChar.self)
}

#endif // ENABLE_KEY_EVENT_TABLES_SWIFT
