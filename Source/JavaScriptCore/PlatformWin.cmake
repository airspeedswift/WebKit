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

# WK_USE_SWIFT_BIGINT_DIGITS is BaseTarget.xcconfig's setting of the same name: JSBigInt's digit arithmetic is compiled
# from Swift (runtime/JSBigIntDigits*.swift) as the module JSCSwift, and JSBigInt.cpp's C++ kernels are not compiled.
option(WK_USE_SWIFT_BIGINT_DIGITS "Compile JSBigInt's digit arithmetic from Swift" OFF)
set(WK_SWIFT_BIGINT_DIGITS_EXTRA_FLAGS "" CACHE STRING "Extra swiftc flags for JSBigInt's Swift digit arithmetic")
if (WK_USE_SWIFT_BIGINT_DIGITS)
    find_program(JSC_SWIFTC swiftc REQUIRED)
    cmake_path(GET JSC_SWIFTC PARENT_PATH _jsc_swift_bin)
    cmake_path(GET _jsc_swift_bin PARENT_PATH _jsc_swift_usr)
    cmake_path(CONVERT "$ENV{SDKROOT}" TO_CMAKE_PATH_LIST _jsc_swift_sdk)
    set(_jsc_swift_lib_dir "${_jsc_swift_sdk}/usr/lib/swift/windows/x86_64")
    if (NOT EXISTS "${_jsc_swift_lib_dir}/swiftCore.lib")
        message(FATAL_ERROR "No swiftCore.lib in ${_jsc_swift_lib_dir}; is SDKROOT set?")
    endif ()

    set(_jsc_swift_sources
        runtime/JSBigIntDigits.swift
        runtime/JSBigIntDigitsAddSub.swift
        runtime/JSBigIntDigitsDivide.swift
        runtime/JSBigIntDigitsFFT.swift
        runtime/JSBigIntDigitsMultiply.swift
        runtime/JSBigIntDigitsPrimitives.swift
    )
    list(TRANSFORM _jsc_swift_sources PREPEND "${JAVASCRIPTCORE_DIR}/")
    set(_jsc_swift_dir "${JavaScriptCore_DERIVED_SOURCES_DIR}/JSCSwift")
    set(_jsc_swift_obj "${_jsc_swift_dir}/JSCSwift.obj")
    set(_jsc_swift_hdr "${JavaScriptCore_DERIVED_SOURCES_DIR}/JSCSwift-Swift.h")
    file(MAKE_DIRECTORY "${_jsc_swift_dir}")

    # libJavaScriptCore.xcconfig's and JavaScriptCore.xcconfig's Swift settings, and CommonBase.xcconfig's language mode,
    # optimization level, visibility, upcoming and experimental features and memory safety flags.
    set(_jsc_swift_flags
        -module-name JSCSwift -wmo -O -swift-version 6
        -sdk "${_jsc_swift_sdk}" -D USE_SWIFT_BIGINT_DIGITS
        -cxx-interoperability-mode=default -Xcc "-fmodule-map-file=${JAVASCRIPTCORE_DIR}/JSCSwiftBoundary.modulemap"
        -Xcc -std=c++2b -Xcc -fno-exceptions -Xcc -fignore-exceptions -Xcc -fvisibility=hidden
        -Xcc -O2 -Xllvm -enable-dfa-jump-thread
        -enable-upcoming-feature ExistentialAny -enable-upcoming-feature InternalImportsByDefault
        -enable-upcoming-feature MemberImportVisibility
        -enable-experimental-feature ImportCxxMembersLazily -enable-experimental-feature SuppressedAssociatedTypes
        -enable-experimental-feature SuppressedAssociatedTypesWithDefaults
        -enable-experimental-feature ForeignReferenceTypeInheritance -enable-experimental-feature SafeInteropWrappers
        -strict-memory-safety -enable-experimental-feature Lifetimes -enable-experimental-feature LifetimeDependence
        -enable-experimental-feature ImportNonPublicCxxMembers -Werror StrictMemorySafety -Werror ForeignReferenceType
        -Werror ExistentialAny
        -Xfrontend -clang-header-expose-decls=has-expose-attr-or-stdlib
        -Xfrontend -emit-clang-header-min-access -Xfrontend internal)
    if (LTO_MODE)
        list(APPEND _jsc_swift_flags -Xfrontend -lto=llvm-${LTO_MODE} -Xfrontend -emit-bc)
    endif ()
    # swiftc targets x86_64 with cmpxchg16b, which clang-cl does not. The Swift functions need the same target
    # features as the C++ that calls them, or the LTO inliner does not inline them into it.
    list(APPEND _jsc_swift_flags -Xcc -mno-cx16)
    separate_arguments(_jsc_swift_extra NATIVE_COMMAND "${WK_SWIFT_BIGINT_DIGITS_EXTRA_FLAGS}")

    add_custom_command(
        OUTPUT "${_jsc_swift_obj}" "${_jsc_swift_hdr}"
        COMMAND "${JSC_SWIFTC}" ${_jsc_swift_flags} ${_jsc_swift_extra}
            -emit-clang-header-path "${_jsc_swift_hdr}"
            -c ${_jsc_swift_sources} -o "${_jsc_swift_obj}"
        DEPENDS ${_jsc_swift_sources} "${JAVASCRIPTCORE_DIR}/JSCSwiftBoundary.modulemap"
            "${JAVASCRIPTCORE_DIR}/runtime/JSBigIntSwiftDigits.h"
        COMMENT "Compiling JSCSwift"
        VERBATIM)
    add_custom_target(JSCSwift DEPENDS "${_jsc_swift_obj}" "${_jsc_swift_hdr}")

    list(APPEND JavaScriptCore_SOURCES "${_jsc_swift_obj}")
    set_source_files_properties("${_jsc_swift_obj}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
    # JSBigInt.cpp, in a unified source, includes the generated header.
    list(APPEND JavaScriptCore_DEPENDENCIES JSCSwift)
    # <swiftToCxx/_SwiftCxxInteroperability.h>, which the generated header includes.
    list(APPEND JavaScriptCore_PRIVATE_INCLUDE_DIRECTORIES "${_jsc_swift_usr}/lib/swift")
    # The import libraries of the Swift runtime the object auto-links.
    string(APPEND CMAKE_SHARED_LINKER_FLAGS " /LIBPATH:\"${_jsc_swift_lib_dir}\"")
    # JSBigInt.h declares its digit helpers only when this is 0, so every JavaScriptCore translation unit gets it.
    add_compile_definitions(USE_SWIFT_BIGINT_DIGITS=1)
endif ()
