/*
 * Copyright (C) 2004-2026 Apple Inc. All rights reserved.
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

// The Mac key-event tables of KeyEventMac.mm and PlatformEventFactoryMac.mm, in Swift.
//
// The tables are checked against the C++ they replace entry by entry, by index for the
// key-code table and by case label for the other two.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_KEY_EVENT_TABLES_SWIFT to swiftc for a truthy ENABLE() macro, so the
// Swift spelling of the same gate is a bare identifier.

#if ENABLE_KEY_EVENT_TABLES_SWIFT

internal import AppKit
internal import Carbon.HIToolbox
// VK_* are object-like macros of single integer literals in WindowsKeyboardCodes.h, a Private
// header under the WebCore_Private umbrella, so they arrive as Int32 constants.
internal import WebCore_Private

/// The Windows virtual key code for each Mac virtual key code in 0x00...0x7E, or 0 where the
/// Mac key has no Windows counterpart.
///
/// Indexed by `NSEvent.keyCode`; see `windowsKeyCodeForKeyCode`.
private let windowsKeyCodeTable: [Swift.Int32] = [
    /* 0 */ VK_A,
    /* 1 */ VK_S,
    /* 2 */ VK_D,
    /* 3 */ VK_F,
    /* 4 */ VK_H,
    /* 5 */ VK_G,
    /* 6 */ VK_Z,
    /* 7 */ VK_X,
    /* 8 */ VK_C,
    /* 9 */ VK_V,
    /* 0x0A */ VK_OEM_3, // "Section" - key to the left from 1 (ISO Keyboard Only)
    /* 0x0B */ VK_B,
    /* 0x0C */ VK_Q,
    /* 0x0D */ VK_W,
    /* 0x0E */ VK_E,
    /* 0x0F */ VK_R,
    /* 0x10 */ VK_Y,
    /* 0x11 */ VK_T,
    /* 0x12 */ VK_1,
    /* 0x13 */ VK_2,
    /* 0x14 */ VK_3,
    /* 0x15 */ VK_4,
    /* 0x16 */ VK_6,
    /* 0x17 */ VK_5,
    /* 0x18 */ VK_OEM_PLUS, // =+
    /* 0x19 */ VK_9,
    /* 0x1A */ VK_7,
    /* 0x1B */ VK_OEM_MINUS, // -_
    /* 0x1C */ VK_8,
    /* 0x1D */ VK_0,
    /* 0x1E */ VK_OEM_6, // ]}
    /* 0x1F */ VK_O,
    /* 0x20 */ VK_U,
    /* 0x21 */ VK_OEM_4, // {[
    /* 0x22 */ VK_I,
    /* 0x23 */ VK_P,
    /* 0x24 */ VK_RETURN, // Return
    /* 0x25 */ VK_L,
    /* 0x26 */ VK_J,
    /* 0x27 */ VK_OEM_7, // '"
    /* 0x28 */ VK_K,
    /* 0x29 */ VK_OEM_1, // ;:
    /* 0x2A */ VK_OEM_5, // \|
    /* 0x2B */ VK_OEM_COMMA, // ,<
    /* 0x2C */ VK_OEM_2, // /?
    /* 0x2D */ VK_N,
    /* 0x2E */ VK_M,
    /* 0x2F */ VK_OEM_PERIOD, // .>
    /* 0x30 */ VK_TAB,
    /* 0x31 */ VK_SPACE,
    /* 0x32 */ VK_OEM_3, // `~
    /* 0x33 */ VK_BACK, // Backspace
    /* 0x34 */ 0, // n/a
    /* 0x35 */ VK_ESCAPE,
    /* 0x36 */ VK_APPS, // Right Command
    /* 0x37 */ VK_LWIN, // Left Command
    /* 0x38 */ VK_LSHIFT, // Left Shift
    /* 0x39 */ VK_CAPITAL, // Caps Lock
    /* 0x3A */ VK_LMENU, // Left Option
    /* 0x3B */ VK_LCONTROL, // Left Ctrl
    /* 0x3C */ VK_RSHIFT, // Right Shift
    /* 0x3D */ VK_RMENU, // Right Option
    /* 0x3E */ VK_RCONTROL, // Right Ctrl
    /* 0x3F */ 0, // fn
    /* 0x40 */ VK_F17,
    /* 0x41 */ VK_DECIMAL, // Num Pad .
    /* 0x42 */ 0, // n/a
    /* 0x43 */ VK_MULTIPLY, // Num Pad *
    /* 0x44 */ 0, // n/a
    /* 0x45 */ VK_ADD, // Num Pad +
    /* 0x46 */ 0, // n/a
    /* 0x47 */ VK_CLEAR, // Num Pad Clear
    /* 0x48 */ VK_VOLUME_UP,
    /* 0x49 */ VK_VOLUME_DOWN,
    /* 0x4A */ VK_VOLUME_MUTE,
    /* 0x4B */ VK_DIVIDE, // Num Pad /
    /* 0x4C */ VK_RETURN, // Num Pad Enter
    /* 0x4D */ 0, // n/a
    /* 0x4E */ VK_SUBTRACT, // Num Pad -
    /* 0x4F */ VK_F18,
    /* 0x50 */ VK_F19,
    /* 0x51 */ VK_OEM_PLUS, // Num Pad =. There is no such key on common PC keyboards, mapping to normal "+=".
    /* 0x52 */ VK_NUMPAD0,
    /* 0x53 */ VK_NUMPAD1,
    /* 0x54 */ VK_NUMPAD2,
    /* 0x55 */ VK_NUMPAD3,
    /* 0x56 */ VK_NUMPAD4,
    /* 0x57 */ VK_NUMPAD5,
    /* 0x58 */ VK_NUMPAD6,
    /* 0x59 */ VK_NUMPAD7,
    /* 0x5A */ VK_F20,
    /* 0x5B */ VK_NUMPAD8,
    /* 0x5C */ VK_NUMPAD9,
    /* 0x5D */ 0, // Yen (JIS Keyboard Only)
    /* 0x5E */ 0, // Underscore (JIS Keyboard Only)
    /* 0x5F */ 0, // KeypadComma (JIS Keyboard Only)
    /* 0x60 */ VK_F5,
    /* 0x61 */ VK_F6,
    /* 0x62 */ VK_F7,
    /* 0x63 */ VK_F3,
    /* 0x64 */ VK_F8,
    /* 0x65 */ VK_F9,
    /* 0x66 */ 0, // Eisu (JIS Keyboard Only)
    /* 0x67 */ VK_F11,
    /* 0x68 */ 0, // Kana (JIS Keyboard Only)
    /* 0x69 */ VK_F13,
    /* 0x6A */ VK_F16,
    /* 0x6B */ VK_F14,
    /* 0x6C */ 0, // n/a
    /* 0x6D */ VK_F10,
    /* 0x6E */ 0, // n/a (Windows95 key?)
    /* 0x6F */ VK_F12,
    /* 0x70 */ 0, // n/a
    /* 0x71 */ VK_F15,
    /* 0x72 */ VK_INSERT, // Help
    /* 0x73 */ VK_HOME, // Home
    /* 0x74 */ VK_PRIOR, // Page Up
    /* 0x75 */ VK_DELETE, // Forward Delete
    /* 0x76 */ VK_F4,
    /* 0x77 */ VK_END, // End
    /* 0x78 */ VK_F2,
    /* 0x79 */ VK_NEXT, // Page Down
    /* 0x7A */ VK_F1,
    /* 0x7B */ VK_LEFT, // Left Arrow
    /* 0x7C */ VK_RIGHT, // Right Arrow
    /* 0x7D */ VK_DOWN, // Down Arrow
    /* 0x7E */ VK_UP, // Up Arrow
]

/// The Windows virtual key code for a Mac virtual key code, or 0 when the table does not
/// name one.
private func windowsKeyCodeForKeyCode(_ keyCode: Swift.UInt16) -> Swift.Int32 {
    let index = Swift.Int(keyCode)
    guard index < windowsKeyCodeTable.count else {
        return 0
    }
    return windowsKeyCodeTable[index]
}

/// The Windows virtual key code for a character code, or 0 when the table does not name one.
///
/// Character codes are spelled as the code points they are, with the AppKit constant named in
/// a comment, so that this file needs no name from AppKit to hold a table of integers.
private func windowsKeyCodeForCharCode(_ charCode: Swift.UInt16) -> Swift.Int32 {
    switch charCode {
    case 0x61, 0x41: // 'a', 'A'
        return VK_A
    case 0x62, 0x42: // 'b', 'B'
        return VK_B
    case 0x63, 0x43: // 'c', 'C'
        return VK_C
    case 0x64, 0x44: // 'd', 'D'
        return VK_D
    case 0x65, 0x45: // 'e', 'E'
        return VK_E
    case 0x66, 0x46: // 'f', 'F'
        return VK_F
    case 0x67, 0x47: // 'g', 'G'
        return VK_G
    case 0x68, 0x48: // 'h', 'H'
        return VK_H
    case 0x69, 0x49: // 'i', 'I'
        return VK_I
    case 0x6A, 0x4A: // 'j', 'J'
        return VK_J
    case 0x6B, 0x4B: // 'k', 'K'
        return VK_K
    case 0x6C, 0x4C: // 'l', 'L'
        return VK_L
    case 0x6D, 0x4D: // 'm', 'M'
        return VK_M
    case 0x6E, 0x4E: // 'n', 'N'
        return VK_N
    case 0x6F, 0x4F: // 'o', 'O'
        return VK_O
    case 0x70, 0x50: // 'p', 'P'
        return VK_P
    case 0x71, 0x51: // 'q', 'Q'
        return VK_Q
    case 0x72, 0x52: // 'r', 'R'
        return VK_R
    case 0x73, 0x53: // 's', 'S'
        return VK_S
    case 0x74, 0x54: // 't', 'T'
        return VK_T
    case 0x75, 0x55: // 'u', 'U'
        return VK_U
    case 0x76, 0x56: // 'v', 'V'
        return VK_V
    case 0x77, 0x57: // 'w', 'W'
        return VK_W
    case 0x78, 0x58: // 'x', 'X'
        return VK_X
    case 0x79, 0x59: // 'y', 'Y'
        return VK_Y
    case 0x7A, 0x5A: // 'z', 'Z'
        return VK_Z

    // AppKit generates Unicode PUA character codes for some function keys; using these when key code is not known.
    case 0xF730: // NSPauseFunctionKey
        return VK_PAUSE
    case 0xF741: // NSSelectFunctionKey
        return VK_SELECT
    case 0xF738: // NSPrintFunctionKey
        return VK_PRINT
    case 0xF742: // NSExecuteFunctionKey
        return VK_EXECUTE
    case 0xF72E: // NSPrintScreenFunctionKey
        return VK_SNAPSHOT
    case 0xF727: // NSInsertFunctionKey
        return VK_INSERT
    case 0xF718: // NSF21FunctionKey
        return VK_F21
    case 0xF719: // NSF22FunctionKey
        return VK_F22
    case 0xF71A: // NSF23FunctionKey
        return VK_F23
    case 0xF71B: // NSF24FunctionKey
        return VK_F24
    case 0xF72F: // NSScrollLockFunctionKey
        return VK_SCROLL

    // This is for U.S. keyboard mapping, and doesn't necessarily make sense for different keyboard layouts.
    // For example, '"' on Windows Russian layout is VK_2, not VK_OEM_7.
    case 0x3B, 0x3A: // ';', ':'
        return VK_OEM_1
    case 0x3D, 0x2B: // '=', '+'
        return VK_OEM_PLUS
    case 0x2C, 0x3C: // ',', '<'
        return VK_OEM_COMMA
    case 0x2D, 0x5F: // '-', '_'
        return VK_OEM_MINUS
    case 0x2E, 0x3E: // '.', '>'
        return VK_OEM_PERIOD
    case 0x2F, 0x3F: // '/', '?'
        return VK_OEM_2
    case 0x60, 0x7E: // '`', '~'
        return VK_OEM_3
    case 0x5B, 0x7B: // '[', '{'
        return VK_OEM_4
    case 0x5C, 0x7C: // '\\', '|'
        return VK_OEM_5
    case 0x5D, 0x7D: // ']', '}'
        return VK_OEM_6
    case 0x27, 0x22: // '\'', '"'
        return VK_OEM_7
    default:
        return 0
    }
}

/// The `code` attribute value for `event`, which is `"Unidentified"` for any key the table
/// does not name.
///
/// https://w3c.github.io/uievents-code/
private func codeForKeyEvent(_ event: AppKit.NSEvent) -> Swift.StaticString {
    switch Swift.Int(event.keyCode) {
    // Keys in the alphanumeric section.
    case kVK_ANSI_Grave:
        return "Backquote"
    case kVK_ANSI_Backslash:
        return "Backslash"
    case kVK_Delete:
        return "Backspace"
    case kVK_ANSI_LeftBracket:
        return "BracketLeft"
    case kVK_ANSI_RightBracket:
        return "BracketRight"
    case kVK_ANSI_Comma:
        return "Comma"
    case kVK_ANSI_0:
        return "Digit0"
    case kVK_ANSI_1:
        return "Digit1"
    case kVK_ANSI_2:
        return "Digit2"
    case kVK_ANSI_3:
        return "Digit3"
    case kVK_ANSI_4:
        return "Digit4"
    case kVK_ANSI_5:
        return "Digit5"
    case kVK_ANSI_6:
        return "Digit6"
    case kVK_ANSI_7:
        return "Digit7"
    case kVK_ANSI_8:
        return "Digit8"
    case kVK_ANSI_9:
        return "Digit9"
    case kVK_ANSI_Equal:
        return "Equal"
    case kVK_ISO_Section:
        return "IntlBackslash"
    case kVK_JIS_Underscore:
        return "IntlRo"
    case kVK_JIS_Yen:
        return "IntlYen"
    case kVK_ANSI_A:
        return "KeyA"
    case kVK_ANSI_B:
        return "KeyB"
    case kVK_ANSI_C:
        return "KeyC"
    case kVK_ANSI_D:
        return "KeyD"
    case kVK_ANSI_E:
        return "KeyE"
    case kVK_ANSI_F:
        return "KeyF"
    case kVK_ANSI_G:
        return "KeyG"
    case kVK_ANSI_H:
        return "KeyH"
    case kVK_ANSI_I:
        return "KeyI"
    case kVK_ANSI_J:
        return "KeyJ"
    case kVK_ANSI_K:
        return "KeyK"
    case kVK_ANSI_L:
        return "KeyL"
    case kVK_ANSI_M:
        return "KeyM"
    case kVK_ANSI_N:
        return "KeyN"
    case kVK_ANSI_O:
        return "KeyO"
    case kVK_ANSI_P:
        return "KeyP"
    case kVK_ANSI_Q:
        return "KeyQ"
    case kVK_ANSI_R:
        return "KeyR"
    case kVK_ANSI_S:
        return "KeyS"
    case kVK_ANSI_T:
        return "KeyT"
    case kVK_ANSI_U:
        return "KeyU"
    case kVK_ANSI_V:
        return "KeyV"
    case kVK_ANSI_W:
        return "KeyW"
    case kVK_ANSI_X:
        return "KeyX"
    case kVK_ANSI_Y:
        return "KeyY"
    case kVK_ANSI_Z:
        return "KeyZ"
    case kVK_ANSI_Minus:
        return "Minus"
    case kVK_ANSI_Period:
        return "Period"
    case kVK_ANSI_Quote:
        return "Quote"
    case kVK_ANSI_Semicolon:
        return "Semicolon"
    case kVK_ANSI_Slash:
        return "Slash"

    // Functional keys in alphanumeric section.
    case kVK_Option:
        return "AltLeft"
    case kVK_RightOption:
        return "AltRight"
    case kVK_CapsLock:
        return "CapsLock"
    // ContextMenu.
    case kVK_Control:
        return "ControlLeft"
    case kVK_RightControl:
        return "ControlRight"
    case kVK_Return: // Labeled Return on Apple keyboards.
        return "Enter"
    case kVK_Command:
        return "MetaLeft"
    case kVK_RightCommand:
        return "MetaRight"
    case kVK_Shift:
        return "ShiftLeft"
    case kVK_RightShift:
        return "ShiftRight"
    case kVK_Space:
        return "Space"
    case kVK_Tab:
        return "Tab"

    // Functional keys found on Japanese and Korean keyboards.
    // Convert.
    case kVK_JIS_Kana:
        return "KanaMode"
    // Lang1.
    case kVK_JIS_Eisu: // Japanese (Mac keyboard): eisu.
        return "Lang2"
    // Lang3.
    // Lang4.
    // Lang5.
    // NonConvert.

    // Keys in the ControlPad section.
    case kVK_ForwardDelete:
        return "Delete"
    case kVK_End:
        return "End"
    case kVK_Help:
        return "Help"
    case kVK_Home:
        return "Home"
    // Insert: Not present on Apple keyboards.
    case kVK_PageDown:
        return "PageDown"
    case kVK_PageUp:
        return "PageUp"

    // Keys in the ArrowPad section.
    case kVK_DownArrow:
        return "ArrowDown"
    case kVK_LeftArrow:
        return "ArrowLeft"
    case kVK_RightArrow:
        return "ArrowRight"
    case kVK_UpArrow:
        return "ArrowUp"

    // Keys in the Numpad section.
    case kVK_ANSI_KeypadClear: // The specification says to use "NumLock" on Mac for the numpad Clear key.
        return "NumLock"
    case kVK_ANSI_Keypad0:
        return "Numpad0"
    case kVK_ANSI_Keypad1:
        return "Numpad1"
    case kVK_ANSI_Keypad2:
        return "Numpad2"
    case kVK_ANSI_Keypad3:
        return "Numpad3"
    case kVK_ANSI_Keypad4:
        return "Numpad4"
    case kVK_ANSI_Keypad5:
        return "Numpad5"
    case kVK_ANSI_Keypad6:
        return "Numpad6"
    case kVK_ANSI_Keypad7:
        return "Numpad7"
    case kVK_ANSI_Keypad8:
        return "Numpad8"
    case kVK_ANSI_Keypad9:
        return "Numpad9"
    case kVK_ANSI_KeypadPlus:
        return "NumpadAdd"
    // NumpadBackspace.
    // NumpadClear: The specification says that the numpad Clear key should always be encoded as "NumLock" on Mac.
    // NumpadClearEntry.
    case kVK_JIS_KeypadComma:
        return "NumpadComma"
    case kVK_ANSI_KeypadDecimal:
        return "NumpadDecimal"
    case kVK_ANSI_KeypadDivide:
        return "NumpadDivide"
    case kVK_ANSI_KeypadEnter:
        return "NumpadEnter"
    case kVK_ANSI_KeypadEquals:
        return "NumpadEqual"
    // NumpadHash.
    // NumpadMemoryAdd.
    // NumpadMemoryClear.
    // NumpadMemoryRecall.
    // NumpadMemoryStore.
    // NumpadMemorySubtract.
    case kVK_ANSI_KeypadMultiply:
        return "NumpadMultiply"
    // NumpadParenLeft.
    // NumpadParenRight.
    // NumpadStar: The specification says to use "NumpadMultiply" for the * key on numeric keypads.
    case kVK_ANSI_KeypadMinus:
        return "NumpadSubtract"

    // Keys in the Function section.
    case kVK_Escape:
        return "Escape"
    case kVK_F1:
        return "F1"
    case kVK_F2:
        return "F2"
    case kVK_F3:
        return "F3"
    case kVK_F4:
        return "F4"
    case kVK_F5:
        return "F5"
    case kVK_F6:
        return "F6"
    case kVK_F7:
        return "F7"
    case kVK_F8:
        return "F8"
    case kVK_F9:
        return "F9"
    case kVK_F10:
        return "F10"
    case kVK_F11:
        return "F11"
    case kVK_F12:
        return "F12"
    case kVK_F13:
        return "F13"
    case kVK_F14:
        return "F14"
    case kVK_F15:
        return "F15"
    case kVK_F16:
        return "F16"
    case kVK_F17:
        return "F17"
    case kVK_F18:
        return "F18"
    case kVK_F19:
        return "F19"
    case kVK_F20:
        return "F20"
    // Fn: This is typically a hardware key that does not generate a separate code.
    // FnLock.
    // PrintScreen.
    // ScrollLock.
    // Pause.

    // Media keys.
    // BrowserBack.
    // BrowserFavorites.
    // BrowserForward.
    // BrowserHome.
    // BrowserRefresh.
    // BrowserSearch.
    // BrowserStop.
    // Eject.
    // LaunchApp1.
    // LaunchApp2.
    // LaunchMail.
    // MediaPlayPause.
    // MediaSelect.
    // MediaStop.
    // MediaTrackNext.
    // MediaTrackPrevious.
    // Power.
    // Sleep.
    case kVK_VolumeDown:
        return "AudioVolumeDown"
    case kVK_Mute:
        return "AudioVolumeMute"
    case kVK_VolumeUp:
        return "AudioVolumeUp"
    // WakeUp.

    // Legacy modifier keys.
    // Hyper.
    // Super.
    // Turbo.

    // Legacy process control keys.
    // Abort.
    // Resume.
    // Suspend.

    // Legacy editing keys.
    // Again.
    // Copy.
    // Cut.
    // Find.
    // Open.
    // Paste.
    // Props.
    // Select.
    // Undo.

    // Keys found on international keyboards.
    // Hiragana.
    // Katakana.

    default:
        return "Unidentified"
    }
}

/// Whether `event` came from the numeric keypad.
private func isKeypadEvent(_ event: AppKit.NSEvent) -> Swift.Bool {
    // Check that this is the type of event that has a keyCode.
    switch event.type {
    case .keyDown, .keyUp, .flagsChanged:
        break
    default:
        return false
    }

    if event.modifierFlags.contains(.numericPad) {
        return true
    }

    switch event.keyCode {
    case 71, // Clear
        81, // =
        75, // /
        67, // *
        78, // -
        69, // +
        76, // Enter
        65, // .
        82, // 0
        83, // 1
        84, // 2
        85, // 3
        86, // 4
        87, // 5
        88, // 6
        89, // 7
        91, // 8
        92: // 9
        return true
    default:
        return false
    }
}

/// The Windows virtual key code for `event`.
private func windowsKeyCodeForKeyEvent(_ event: AppKit.NSEvent) -> Swift.Int32 {
    // There are several kinds of characters for which we produce key code from char code:
    // 1. Roman letters. Windows keyboard layouts affect both virtual key codes and character codes for these,
    //    so e.g. 'A' gets the same keyCode on QWERTY, AZERTY or Dvorak layouts.
    // 2. Keys for which there is no known Mac virtual key codes, like PrintScreen.
    // 3. Certain punctuation keys. On Windows, these are also remapped depending on current keyboard layout,
    //    but see comment in windowsKeyCodeForCharCode().
    if !isKeypadEvent(event) && (event.type == .keyDown || event.type == .keyUp) {
        // Cmd switches Roman letters for Dvorak-QWERTY layout, so try modified characters first.
        if let charCode = event.characters?.utf16.first {
            let code = windowsKeyCodeForCharCode(charCode)
            if code != 0 {
                return code
            }
        }

        // Ctrl+A on an AZERTY keyboard would get VK_Q keyCode if we relied on -[NSEvent keyCode] below.
        if let charCode = event.charactersIgnoringModifiers?.utf16.first {
            let code = windowsKeyCodeForCharCode(charCode)
            if code != 0 {
                return code
            }
        }
    }

    // Map Mac virtual key code directly to Windows one for any keys not handled above.
    // E.g. the key next to Caps Lock has the same Event.keyCode on U.S. keyboard ('A') and on Russian keyboard (CYRILLIC LETTER EF).
    return windowsKeyCodeForKeyCode(event.keyCode)
}

/// The `code` attribute value for `event`, as a pointer to static storage plus its length in
/// bytes, which the caller in PlatformEventFactoryMac.mm turns back into a `WTF::String`.
///
/// WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO and declares no
/// SWIFT_OBJC_INTERFACE_HEADER_NAME, so C++ cannot name a Swift declaration and the only
/// boundary available is `@_cdecl`, which cannot carry a `WTF::String`. Every value this table
/// produces is a fixed ASCII literal, `"Unidentified"` included, so the result is always
/// static storage and never needs a caller-owned buffer.
///
/// Internal rather than public because it names `NSEvent`, which arrives through an internal
/// import. `@_cdecl` exports the C symbol regardless of access level.
@_cdecl("WebCoreCodeForKeyEvent")
func webCoreCodeForKeyEvent(
    _ event: AppKit.NSEvent,
    _ length: Swift.UnsafeMutablePointer<Swift.Int>
) -> Swift.UnsafePointer<Swift.CChar> {
    let code = codeForKeyEvent(event)
    // SAFETY: the caller passes the address of one of its own locals, so it addresses a
    // writable Int for the duration of this call.
    // Not provable today because @_cdecl cannot take an `inout` or a MutableSpan parameter, so
    // the out-parameter crosses as a bare pointer.
    unsafe length.pointee = code.utf8CodeUnitCount
    // SAFETY: a StaticString's utf8Start addresses static storage, so the pointer outlives
    // every caller and no lifetime is being asserted.
    return unsafe Swift.UnsafeRawPointer(code.utf8Start).assumingMemoryBound(to: Swift.CChar.self)
}

/// Whether `event` came from the numeric keypad.
///
/// The `NSEvent` crosses at +0, as it did before this moved to Swift: an `@_cdecl` parameter of
/// object type is not consumed.
@_cdecl("WebCoreIsKeypadEvent")
func webCoreIsKeypadEvent(_ event: AppKit.NSEvent) -> Swift.Bool {
    isKeypadEvent(event)
}

/// The Windows virtual key code for `event`.
///
/// See `webCoreIsKeypadEvent` for the `NSEvent` convention. The two tables this consults are
/// private to this file, so neither crosses the boundary.
@_cdecl("WebCoreWindowsKeyCodeForKeyEvent")
func webCoreWindowsKeyCodeForKeyEvent(_ event: AppKit.NSEvent) -> Swift.Int32 {
    windowsKeyCodeForKeyEvent(event)
}

#endif // ENABLE_KEY_EVENT_TABLES_SWIFT
