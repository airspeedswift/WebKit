list(APPEND PAL_SOURCES
    crypto/openssl/CryptoDigestOpenSSL.cpp

    system/ClockGeneric.cpp

    system/win/SoundWin.cpp

    text/KillRing.cpp
)

list(APPEND PAL_PRIVATE_LIBRARIES
    OpenSSL::Crypto
)

if (WK_USE_SWIFT_TEXT_CODEC_UTF8)
    # TextCodecUTF8.swift imports pal.Core.text.TextCodecUTF8SwiftTypes.
    list(APPEND PAL_PUBLIC_HEADERS module.modulemap)

    # module.modulemap has `umbrella "spi"`, which Clang requires to be a non-empty directory.
    file(MAKE_DIRECTORY "${PAL_HEADERS_DIR}/spi")
    file(WRITE "${PAL_HEADERS_DIR}/spi/pal_spi_stub.h" "")

    # The same amended MSVC STL and WinSDK modulemaps Source/WebKit/PlatformWin.cmake mounts for
    # WebKit's Swift, which is configured after PAL. See that file.
    cmake_path(CONVERT "$ENV{SDKROOT}" TO_CMAKE_PATH_LIST _swift_sdkroot)
    cmake_path(CONVERT "$ENV{VCToolsInstallDir}" TO_CMAKE_PATH_LIST _vc_tools_dir)
    set(_sdk_vcruntime_mm "${_swift_sdkroot}/usr/share/vcruntime.modulemap")
    set(_sdk_winsdk_um_mm "${_swift_sdkroot}/usr/share/winsdk_um.modulemap")
    if (_swift_sdkroot AND _vc_tools_dir AND EXISTS "${_sdk_vcruntime_mm}")
        file(GLOB _msvc_internal_headers CONFIGURE_DEPENDS
            RELATIVE "${_vc_tools_dir}/include"
            "${_vc_tools_dir}/include/__msvc_*.hpp")
        execute_process(
            COMMAND ${PYTHON_EXECUTABLE} "${CMAKE_SOURCE_DIR}/Source/WebKit/Scripts/generate-msvc-stl-modulemap.py"
                --sdk-modulemap "${_sdk_vcruntime_mm}"
                --winsdk-um-modulemap "${_sdk_winsdk_um_mm}"
                --output-dir "${CMAKE_BINARY_DIR}/windows-modulemaps"
                --headers ${_msvc_internal_headers}
            OUTPUT_VARIABLE _pal_win_vfs_overlay
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_VARIABLE _pal_win_mm_error
            RESULT_VARIABLE _pal_win_mm_result)
        if (NOT _pal_win_mm_result EQUAL 0)
            message(FATAL_ERROR "Could not generate the amended MSVC STL modulemap for PAL's Swift:\n${_pal_win_mm_error}")
        endif ()
        if (_pal_win_vfs_overlay)
            list(APPEND PAL_PLATFORM_SWIFT_CLANG_FLAG_PAIRS "-vfsoverlay ${_pal_win_vfs_overlay}")
        endif ()
    else ()
        message(FATAL_ERROR "PAL's Swift needs SDKROOT and VCToolsInstallDir (SDKROOT='$ENV{SDKROOT}', VCToolsInstallDir='$ENV{VCToolsInstallDir}')")
    endif ()
endif ()
