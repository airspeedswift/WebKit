list(APPEND JavaScriptCore_SOURCES
    API/JSStringRefBSTR.cpp
)

list(APPEND JavaScriptCore_PUBLIC_FRAMEWORK_HEADERS
    API/JSStringRefBSTR.h
    API/JavaScriptCore.h
)

if (ENABLE_REMOTE_INSPECTOR)
    include(inspector/remote/Socket.cmake)
else ()
    list(REMOVE_ITEM JavaScriptCore_SOURCES
        inspector/JSGlobalObjectInspectorController.cpp
    )
endif ()

# WK_USE_SWIFT_JSON_PARSER is the counterpart of BaseTarget.xcconfig's setting of the same name: LiteralParser parses
# in Swift (runtime/LiteralParserSwift.swift), and LiteralParser.cpp's parser is not compiled. The Swift imports only
# LiteralParserSwiftTypes.h, which includes only the standard library, so one command compiles it whole-module into
# an object JavaScriptCore links, and writes the JavaScriptCore-Swift.h that LiteralParserSwiftFacade.cpp includes.
# Under LTO_MODE the object is LLVM bitcode with a ThinLTO summary, so the link optimizes the Swift with its C++.
option(WK_USE_SWIFT_JSON_PARSER "Parse JSON with LiteralParser's Swift implementation" OFF)
if (WK_USE_SWIFT_JSON_PARSER)
    find_program(JSC_SWIFTC swiftc REQUIRED)
    cmake_path(GET JSC_SWIFTC PARENT_PATH _jsc_swift_bin)
    cmake_path(GET _jsc_swift_bin PARENT_PATH _jsc_swift_usr)
    cmake_path(CONVERT "$ENV{SDKROOT}" TO_CMAKE_PATH_LIST _jsc_swift_sdk)
    if (WTF_CPU_ARM64)
        set(_jsc_swift_arch aarch64)
    else ()
        set(_jsc_swift_arch x86_64)
    endif ()
    set(_jsc_swift_lib_dir "${_jsc_swift_sdk}/usr/lib/swift/windows/${_jsc_swift_arch}")
    if (NOT EXISTS "${_jsc_swift_lib_dir}/swiftCore.lib")
        message(FATAL_ERROR "No swiftCore.lib in ${_jsc_swift_lib_dir}; is SDKROOT set?")
    endif ()

    set(_jsc_swift_dir "${JavaScriptCore_DERIVED_SOURCES_DIR}/LiteralParserSwift")
    set(_jsc_swift_obj "${_jsc_swift_dir}/LiteralParserSwift.obj")
    set(_jsc_swift_hdr "${JavaScriptCore_DERIVED_SOURCES_DIR}/JavaScriptCore-Swift.h")
    file(MAKE_DIRECTORY "${_jsc_swift_dir}")
    # JavaScriptCore_Private.modulemap's LiteralParserSwiftTypes, the one submodule the Swift imports.
    file(WRITE "${_jsc_swift_dir}/module.modulemap"
        "module JavaScriptCore_Private {\n"
        "    explicit module LiteralParserSwiftTypes {\n"
        "        header \"${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwiftTypes.h\"\n"
        "        requires cplusplus\n"
        "        export *\n"
        "    }\n"
        "}\n")

    # JavaScriptCore.xcconfig's and CommonBase.xcconfig's Swift settings for this file, with CodeView debug info for the
    # PDB.
    set(_jsc_swift_flags
        -module-name JavaScriptCore -parse-as-library -wmo -O -num-threads 0 -swift-version 6
        -sdk "${_jsc_swift_sdk}" -D USE_SWIFT_JSON_PARSER -g -debug-info-format=codeview
        -cxx-interoperability-mode=default -Xcc -std=c++2b -Xcc -fvisibility=hidden -Xcc "-I${_jsc_swift_dir}"
        -Xcc -O2 -Xllvm -enable-dfa-jump-thread
        -enable-upcoming-feature ExistentialAny -enable-upcoming-feature InternalImportsByDefault
        -enable-upcoming-feature MemberImportVisibility
        -enable-experimental-feature ImportCxxMembersLazily -enable-experimental-feature SuppressedAssociatedTypes
        -enable-experimental-feature SuppressedAssociatedTypesWithDefaults
        -enable-experimental-feature ImportNonPublicCxxMembers -enable-experimental-feature LifetimeDependence
        -enable-experimental-feature Lifetimes -enable-experimental-feature SafeInteropWrappers
        -strict-memory-safety -warnings-as-errors -Werror SendableClosureCaptures
        -Xfrontend -clang-header-expose-decls=has-expose-attr-or-stdlib
        -Xfrontend -emit-clang-header-min-access -Xfrontend internal)
    if (LTO_MODE)
        list(APPEND _jsc_swift_flags -Xfrontend -lto=llvm-${LTO_MODE} -Xfrontend -emit-bc)
    endif ()

    add_custom_command(
        OUTPUT "${_jsc_swift_obj}" "${_jsc_swift_hdr}"
        COMMAND "${JSC_SWIFTC}" ${_jsc_swift_flags}
            -emit-clang-header-path "${_jsc_swift_hdr}"
            -c "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwift.swift" -o "${_jsc_swift_obj}"
        DEPENDS "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwift.swift" "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwiftTypes.h"
        COMMENT "Compiling LiteralParserSwift.swift"
        VERBATIM)

    list(APPEND JavaScriptCore_SOURCES runtime/LiteralParserSwiftFacade.cpp "${_jsc_swift_obj}")
    set_source_files_properties("${_jsc_swift_obj}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
    set_source_files_properties(runtime/LiteralParserSwiftFacade.cpp PROPERTIES OBJECT_DEPENDS "${_jsc_swift_hdr}")
    # <swiftToCxx/_SwiftCxxInteroperability.h>, which the generated header includes.
    list(APPEND JavaScriptCore_PRIVATE_INCLUDE_DIRECTORIES "${_jsc_swift_usr}/lib/swift")
    # The import libraries of the Swift runtime the object auto-links.
    string(APPEND CMAKE_SHARED_LINKER_FLAGS " /LIBPATH:\"${_jsc_swift_lib_dir}\"")
    string(APPEND CMAKE_EXE_LINKER_FLAGS " /LIBPATH:\"${_jsc_swift_lib_dir}\"")
    # Every C++ translation unit that includes LiteralParser.h must agree on the class it declares.
    add_compile_definitions(USE_SWIFT_JSON_PARSER=1)
endif ()
