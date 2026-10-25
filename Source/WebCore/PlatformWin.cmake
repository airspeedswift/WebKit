# Not add_definitions: /bigobj would reach swiftc too, when WebCore has Swift.
add_compile_options("$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:/bigobj>")
add_compile_definitions(__STDC_CONSTANT_MACROS)

include(platform/Adwaita.cmake)
include(platform/Curl.cmake)
include(platform/ImageDecoders.cmake)
include(platform/OpenSSL.cmake)
include(platform/TextureMapper.cmake)

if (USE_CAIRO)
    include(platform/Cairo.cmake)
elseif (USE_SKIA)
    include(platform/Skia.cmake)
endif ()

if (USE_DAWN)
    include(platform/Dawn.cmake)
endif ()

list(APPEND WebCore_PRIVATE_INCLUDE_DIRECTORIES
    "${WEBCORE_DIR}/accessibility/win"
    "${WEBCORE_DIR}/page/win"
    "${WEBCORE_DIR}/platform/graphics/egl"
    "${WEBCORE_DIR}/platform/graphics/opengl"
    "${WEBCORE_DIR}/platform/graphics/opentype"
    "${WEBCORE_DIR}/platform/graphics/win"
    "${WEBCORE_DIR}/platform/mediacapabilities"
    "${WEBCORE_DIR}/platform/network/win"
    "${WEBCORE_DIR}/platform/video-codecs"
    "${WEBCORE_DIR}/platform/win"
)

list(APPEND WebCore_SOURCES
    accessibility/win/AXObjectCacheWin.cpp
    accessibility/win/AccessibilityObjectWin.cpp
    accessibility/win/AccessibilityObjectWrapperWin.cpp

    editing/win/EditorWin.cpp

    html/HTMLSelectElementWin.cpp

    page/win/DragControllerWin.cpp
    page/win/EventHandlerWin.cpp
    page/win/FrameWin.cpp
    page/win/QuirkTableWin.cpp
    page/win/ResourceUsageOverlayWin.cpp
    page/win/ResourceUsageThreadWin.cpp

    platform/Cursor.cpp
    platform/LocalizedStrings.cpp
    platform/StaticPasteboard.cpp

    platform/audio/PlatformMediaSessionManager.cpp

    platform/generic/KeyedDecoderGeneric.cpp
    platform/generic/KeyedEncoderGeneric.cpp

    platform/graphics/PlatformDisplay.cpp

    platform/graphics/angle/PlatformDisplayANGLE.cpp

    platform/graphics/egl/BitmapTexture.cpp
    platform/graphics/egl/BitmapTexturePool.cpp
    platform/graphics/egl/GLContext.cpp
    platform/graphics/egl/GLContextWrapper.cpp
    platform/graphics/egl/GLDisplay.cpp
    platform/graphics/egl/GLFence.cpp
    platform/graphics/egl/GLFenceEGL.cpp
    platform/graphics/egl/GLFenceGL.cpp
    platform/graphics/egl/GraphicsContextGLEGL.cpp

    platform/graphics/opentype/OpenTypeUtilities.cpp

    platform/graphics/win/DIBPixelData.cpp
    platform/graphics/win/DisplayRefreshMonitorWin.cpp
    platform/graphics/win/FloatPointWin.cpp
    platform/graphics/win/FloatRectWin.cpp
    platform/graphics/win/FullScreenController.cpp
    platform/graphics/win/FullScreenWindow.cpp
    platform/graphics/win/GraphicsContextWin.cpp
    platform/graphics/win/IconWin.cpp
    platform/graphics/win/ImageAdapterWin.cpp
    platform/graphics/win/IntPointWin.cpp
    platform/graphics/win/IntRectWin.cpp
    platform/graphics/win/IntSizeWin.cpp
    platform/graphics/win/MediaPlayerPrivateMediaFoundation.cpp
    platform/graphics/win/PlatformDisplayWin.cpp
    platform/graphics/win/SystemFontDatabaseWin.cpp
    platform/graphics/win/TransformationMatrixWin.cpp

    platform/network/win/CurlSSLHandleWin.cpp
    platform/network/win/NetworkStateNotifierWin.cpp

    platform/text/Hyphenation.cpp
    platform/text/LocaleICU.cpp

    platform/win/BString.cpp
    platform/win/BitmapInfo.cpp
    platform/win/ClipboardUtilitiesWin.cpp
    platform/win/CursorWin.cpp
    platform/win/DragDataWin.cpp
    platform/win/GDIUtilities.cpp
    platform/win/KeyEventWin.cpp
    platform/win/LoggingWin.cpp
    platform/win/MIMETypeRegistryWin.cpp
    platform/win/MainThreadSharedTimerWin.cpp
    platform/win/PasteboardWin.cpp
    platform/win/PlatformMouseEventWin.cpp
    platform/win/PlatformPasteboardWin.cpp
    platform/win/PlatformScreenWin.cpp
    platform/win/SearchPopupMenuDB.cpp
    platform/win/SharedMemoryWin.cpp
    platform/win/SystemInfo.cpp
    platform/win/UserAgentWin.cpp
    platform/win/WCDataObject.cpp
    platform/win/WebCoreBundleWin.cpp
    platform/win/WebCoreInstanceHandle.cpp
    platform/win/WebCoreTextRenderer.cpp
    platform/win/WheelEventWin.cpp
    platform/win/WindowMessageBroadcaster.cpp
    platform/win/WindowsKeyNames.cpp
)

list(APPEND WebCore_PRIVATE_FRAMEWORK_HEADERS
    accessibility/win/AccessibilityObjectWrapperWin.h

    page/win/FrameWin.h

    platform/graphics/opentype/FontMemoryResource.h

    platform/graphics/win/DIBPixelData.h
    platform/graphics/win/FullScreenController.h
    platform/graphics/win/FullScreenControllerClient.h
    platform/graphics/win/FullScreenWindow.h
    platform/graphics/win/LocalWindowsContext.h
    platform/graphics/win/SharedGDIObject.h

    platform/win/BString.h
    platform/win/BitmapInfo.h
    platform/win/COMPtr.h
    platform/win/GDIUtilities.h
    platform/win/HWndDC.h
    platform/win/SearchPopupMenuDB.h
    platform/win/SystemInfo.h
    platform/win/WCDataObject.h
    platform/win/WebCoreBundleWin.h
    platform/win/WebCoreTextRenderer.h
    platform/win/WindowMessageBroadcaster.h
    platform/win/WindowMessageListener.h
    platform/win/WindowsKeyNames.h
)

list(APPEND WebCore_LIBRARIES
    crypt32
    iphlpapi
    usp10
    ws2_32
)

list(APPEND WebCoreTestSupport_LIBRARIES
    shlwapi
)

set(iconFiles
    Resources/missingImage.png
    Resources/missingImage@2x.png
    Resources/missingImage@3x.png
    Resources/panIcon.png
    Resources/textAreaResizeCorner.png
    Resources/textAreaResizeCorner@2x.png
)

file(COPY ${iconFiles} DESTINATION ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/WebKit.resources/icons)

configure_file(page/QuirkTable.json ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/WebKit.resources/quirks/QuirkTable.json COPYONLY)

file(COPY ${ModernMediaControlsImageFiles}
    DESTINATION
    ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/WebKit.resources/media-controls
)

if (ENABLE_VIDEO AND USE_MEDIA_FOUNDATION)
    # Define a INTERFACE library for MediaFoundation and link it
    # explicitly with direct WebCore consumers because /DELAYLOAD causes
    # linker warnings for modules not using MediaFoundation.
    #  LINK : warning LNK4199: /DELAYLOAD:mf.dll ignored; no imports found from mf.dll
    add_library(MediaFoundation INTERFACE)
    target_link_libraries(MediaFoundation INTERFACE
        d3d9
        delayimp
        dwrite
        dxva2
        evr
        mf
        mfplat
        mfuuid
        strmiids
    )
    target_link_options(MediaFoundation INTERFACE
        /DELAYLOAD:d3d9.dll
        /DELAYLOAD:dxva2.dll
        /DELAYLOAD:evr.dll
        /DELAYLOAD:mf.dll
        /DELAYLOAD:mfplat.dll
    )

    list(APPEND WebCore_PRIVATE_LIBRARIES MediaFoundation)
endif ()

if (USE_CAIRO)
    list(APPEND WebCore_SOURCES
        platform/graphics/win/ComplexTextControllerUniscribe.cpp
        platform/graphics/win/FontCacheWin.cpp
        platform/graphics/win/FontCustomPlatformDataWin.cpp
        platform/graphics/win/FontDescriptionWin.cpp
        platform/graphics/win/FontPlatformDataWin.cpp
        platform/graphics/win/FontWin.cpp
        platform/graphics/win/GlyphPageTreeNodeWin.cpp
        platform/graphics/win/SimpleFontDataWin.cpp

        platform/graphics/win/cairo/FontCacheWinCairo.cpp
        platform/graphics/win/cairo/FontCustomPlatformDataWinCairo.cpp
        platform/graphics/win/cairo/FontPlatformDataWinCairo.cpp
        platform/graphics/win/cairo/GraphicsContextWinCairo.cpp
        platform/graphics/win/cairo/ImageAdapterWinCairo.cpp
        platform/graphics/win/cairo/MediaPlayerPrivateMediaFoundationCairo.cpp

        platform/win/cairo/DragImageWinCairo.cpp
    )
elseif (USE_SKIA)
    list(APPEND WebCore_SOURCES
        platform/graphics/win/FontCacheSkiaWin.cpp

        platform/skia/DragImageSkia.cpp
    )
endif ()

if (USE_WOFF2)
    # The WOFF2 libraries don't compile as DLLs on Windows, so add in
    # the additional libraries WOFF2::dec requires
    list(APPEND WebCore_LIBRARIES
        Brotli::dec
        WOFF2::common
    )
endif ()

if (USE_SKIA)
    list(APPEND WebCore_PRIVATE_LIBRARIES ${SHARPYUV_LIBS})
endif ()

if (WK_BUILD_WEBCORE_SWIFT)
    # The same amended MSVC STL and WinSDK modulemaps Source/WebKit/PlatformWin.cmake mounts for
    # WebKit's Swift, which is configured after WebCore. See that file.
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
            OUTPUT_VARIABLE _webcore_win_vfs_overlay
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_VARIABLE _webcore_win_mm_error
            RESULT_VARIABLE _webcore_win_mm_result)
        if (NOT _webcore_win_mm_result EQUAL 0)
            message(FATAL_ERROR "Could not generate the amended MSVC STL modulemap for WebCore's Swift:\n${_webcore_win_mm_error}")
        endif ()
        if (_webcore_win_vfs_overlay)
            list(APPEND WebCore_PLATFORM_SWIFT_CLANG_FLAG_PAIRS "-vfsoverlay ${_webcore_win_vfs_overlay}")
        endif ()
    else ()
        message(FATAL_ERROR "WebCore's Swift needs SDKROOT and VCToolsInstallDir (SDKROOT='$ENV{SDKROOT}', VCToolsInstallDir='$ENV{VCToolsInstallDir}')")
    endif ()
endif ()
