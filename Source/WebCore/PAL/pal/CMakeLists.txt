set(PAL_PUBLIC_HEADERS
    ExportMacros.h
    FileSizeFormatter.h
    HysteresisActivity.h
    Logging.h
    SessionID.h
    ThreadGlobalData.h

    crypto/CryptoDigest.h
    crypto/CryptoTypes.h

    system/Clock.h
    system/ClockGeneric.h
    system/SleepDisabler.h
    system/Sound.h
    system/SystemSleepListener.h

    text/DecodeEscapeSequences.h
    text/EncodingTables.h
    text/KillRing.h
    text/TextCodec.h
    text/TextCodecASCIIFastPath.h
    text/TextCodecCJK.h
    text/TextCodecICU.h
    text/TextCodecLatin1.h
    text/TextCodecReplacement.h
    text/TextCodecSingleByte.h
    text/TextCodecUTF16.h
    text/TextCodecUTF8.h
    text/TextCodecUTF8DecoderTypes.h
    text/TextCodecUserDefined.h
    text/TextEncoding.h
    text/TextEncodingDetector.h
    text/TextEncodingRegistry.h
    text/UnencodableHandling.h
)

list(APPEND PAL_UNIFIED_SOURCE_LIST_FILES
    "Sources.txt"
)

set(PAL_PRIVATE_INCLUDE_DIRECTORIES
    "${CMAKE_BINARY_DIR}"
    "${PAL_DERIVED_SOURCES_DIR}"
    # Exclude PAL source dirs from Swift -- the source tree contains module.modulemap
    # which conflicts with the installed copy. Use generator expressions to include
    # them only for C/C++/ObjC.
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${PAL_DIR}>"
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${PAL_DIR}/pal>"
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${PAL_DIR}/pal/crypto>"
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${PAL_DIR}/pal/system>"
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${PAL_DIR}/pal/text>"
)

set(PAL_FRAMEWORKS
    WTF
    bmalloc
)
if (USE_APPLE_INTERNAL_SDK)
    list(APPEND PAL_FRAMEWORKS WebKitAdditions)
endif ()

set(PAL_INTERFACE_LIBRARIES PAL)
set(PAL_INTERFACE_INCLUDE_DIRECTORIES ${PAL_FRAMEWORK_HEADERS_DIR})
set(PAL_INTERFACE_DEPENDENCIES PAL_CopyHeaders)

WEBKIT_FRAMEWORK_DECLARE(PAL)
WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS()
WEBKIT_ADD_TARGET_UNSAFE_BUFFER_WARNINGS(PAL)

if (SWIFT_REQUIRED AND APPLE)
    set(PAL_SWIFT_INTEROP_SOURCES
        crypto/CryptoAlgorithmAESGCMCocoa.cpp
        crypto/CryptoAlgorithmAESKWCocoaBridging.cpp
        crypto/CryptoAlgorithmEd25519CocoaBridging.cpp
        crypto/CryptoAlgorithmHKDFCocoaBridging.cpp
        crypto/CryptoAlgorithmHMACCocoaBridging.cpp
        crypto/CryptoAlgorithmX25519CocoaBridging.cpp
        crypto/CryptoEDKeyBridging.cpp
        crypto/PlatformECKey.cpp

        crypto/commoncrypto/CryptoDigestCommonCrypto.cpp
    )
endif ()
# Set by WK_USE_SWIFT_TEXT_CODEC_UTF8, the counterpart of the PAL.xcconfig setting. TextCodecUTF8.cpp
# then includes PALSwift-Generated.h, so it compiles after the Swift module like the other interop
# sources.
if (WK_USE_SWIFT_TEXT_CODEC_UTF8)
    list(APPEND PAL_SWIFT_INTEROP_SOURCES text/TextCodecUTF8.cpp)
endif ()
foreach (_f IN LISTS PAL_SWIFT_INTEROP_SOURCES)
    cmake_path(GET _f FILENAME _fn)
    list(APPEND PAL_UNIFIED_SOURCE_EXCLUDES "(^|/)${_fn}( |$)")
endforeach ()

WEBKIT_COMPUTE_SOURCES(PAL)

if (DEFINED PAL_SWIFT_INTEROP_SOURCES)
    list(REMOVE_ITEM PAL_SOURCES ${PAL_SWIFT_INTEROP_SOURCES})
    list(APPEND PAL_INTERFACE_LIBRARIES "$<TARGET_OBJECTS:PAL_SwiftInterop>")
endif ()

WEBKIT_COPY_FILES(PAL_CopyHeaders
    DESTINATION ${PAL_HEADERS_DIR}
    FILES ${PAL_PUBLIC_HEADERS}
)

set(PAL_SWIFT_SOURCES "")
if (SWIFT_REQUIRED AND APPLE)
    list(APPEND PAL_SWIFT_SOURCES
        ${PAL_DIR}/pal/pal.swift
        ${PAL_DIR}/pal/system/cocoa/RegexHelper.swift
        ${PAL_DIR}/pal/crypto/CryptoKitShim.swift
        ${PAL_DIR}/pal/crypto/WTFExtras.swift
        ${PAL_DIR}/pal/text/SIMDTableLookup.swift
        ${PAL_DIR}/pal/text/TextCodecUTF8.swift
    )
elseif (WK_USE_SWIFT_TEXT_CODEC_UTF8)
    list(APPEND PAL_SWIFT_SOURCES
        ${PAL_DIR}/pal/text/SIMDTableLookup.swift
        ${PAL_DIR}/pal/text/TextCodecUTF8.swift)
endif ()

if (PAL_SWIFT_SOURCES)
    target_sources(PAL PRIVATE ${PAL_SWIFT_SOURCES})

    WEBKIT_SETUP_SWIFT_AND_GENERATE_SWIFT_CPP_INTEROP_HEADER(PAL pal
        "${PAL_HEADERS_DIR}"
        "PALSwift-Generated.h")

    webkit_target_add_swift_options(PAL
        "-library-level spi"
        "-Xcc -I${PAL_FRAMEWORK_HEADERS_DIR}"
        "-Xcc -I${WTF_FRAMEWORK_HEADERS_DIR}"
        "-Xcc -I${CMAKE_BINARY_DIR}/ICU/Headers"
        "-Xcc -I${bmalloc_FRAMEWORK_HEADERS_DIR}"
        "-Xcc -I${CMAKE_BINARY_DIR}"
        "-Xcc -I${PAL_DERIVED_SOURCES_DIR}"
    )
    if (NOT APPLE)
        # On Apple platforms the interop macro already adds this; elsewhere PAL's
        # Swift still extends its underlying module and needs it explicitly.
        webkit_target_add_swift_options(PAL -import-underlying-module)
        # Apple applies these to every Swift target; PAL's Swift is written against them.
        webkit_target_add_swift_options(PAL
            ${WEBKIT_SWIFT_EXPERIMENTAL_FEATURE_FLAGS}
            ${WEBKIT_SWIFT_MEMORY_SAFETY_FLAGS}
            "-Xcc -fmodule-map-file=${WTF_HEADERS_DIR}/module.modulemap"
            ${PAL_PLATFORM_SWIFT_CLANG_FLAG_PAIRS}
        )
    endif ()
    if (WK_USE_SWIFT_TEXT_CODEC_UTF8)
        # Private to PAL, as in PAL.xcconfig. A Swift compilation condition too, so that without it
        # TextCodecUTF8.swift compiles to nothing.
        target_compile_definitions(PAL PRIVATE
            "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:USE_SWIFT_TEXT_CODEC_UTF8=1>")
        webkit_target_add_swift_options(PAL "-D USE_SWIFT_TEXT_CODEC_UTF8")
        # SIMDTableLookup.swift's table lookup (PSHUFB with SSSE3) needs the Builtin module, as in PAL.xcconfig.
        webkit_target_add_swift_options(PAL "-enable-experimental-feature BuiltinModule")
        if (CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
            webkit_target_add_swift_options(PAL "-D HAVE_SSSE3")
            # HAVE_SSSE3 only chooses PSHUFB; the code generator must be allowed SSSE3 too, or the (LTO)
            # backend cannot select it. nehalem is x86-64-v2 (SSSE3, SSE4.2).
            webkit_target_add_swift_options(PAL "-target-cpu nehalem")
        endif ()
    endif ()
    if (LTO_MODE AND NOT APPLE)
        # Otherwise an LTO build is C++-only: the Swift decoder would be machine code that the LTO
        # link cannot inline into or optimize with its C++ caller. Xcode's counterpart is SWIFT_LTO.
        # Not the driver's -lto=llvm-thin: that writes <name>.bc to the working directory, because
        # CMake's output file map has only an "object" entry, so the object CMake links is never
        # written. Asking the frontend for bitcode puts it in the object, with the ThinLTO summary.
        # This needs whole-module mode: with a separate emit-module job, -emit-bc would override
        # that job's -emit-module too.
        if (WEBKIT_SWIFT_WHOLE_MODULE)
            webkit_target_add_swift_options(PAL
                "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<NOT:$<CONFIG:Debug>>>:SHELL:-Xfrontend -lto=llvm-${LTO_MODE}>"
                "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<NOT:$<CONFIG:Debug>>>:SHELL:-Xfrontend -emit-bc>")
        else ()
            message(WARNING "LTO_MODE is set but Swift is not whole-module (DEVELOPER_MODE), so PAL's Swift is not LTO'd")
        endif ()
    endif ()
endif ()

WEBKIT_FRAMEWORK(PAL)
WEBKIT_ADD_PREFIX_HEADER(PAL PALPrefix.h PREFIX_LANGUAGES CXX OBJCXX)

if (DEFINED PAL_SWIFT_INTEROP_SOURCES)
    WEBKIT_DEFINE_SUBTARGET(PAL_SwiftInterop PAL ${PAL_SWIFT_INTEROP_SOURCES})
    target_precompile_headers(PAL_SwiftInterop REUSE_FROM PAL)
    add_dependencies(PAL_SwiftInterop PAL_CopyHeaders)
endif ()

