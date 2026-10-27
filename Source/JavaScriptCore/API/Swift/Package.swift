// swift-tools-version: 6.2

import PackageDescription

// SafeJSC: a stack-rooted, strictly memory-safe Swift API over JavaScriptCore's C API.
//
// For now this is a stand-alone package built against the JavaScriptCore framework; see
// README.md for where it is meant to go in the JavaScriptCore Swift overlay. It builds only
// with a compiler that has throwing yielding accessors and yield-once functions (a
// coroutine-enhanced Swift 6.5-dev toolchain, passed in with SWIFT_EXEC). The library is the
// only code that says `unsafe`: strict memory safety is an error here.

let settings: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
    .enableExperimentalFeature("Lifetimes"),
    .enableExperimentalFeature("CoroutineAccessors"),
    .enableExperimentalFeature("CoroutineFunctions"),
]

let package = Package(
    name: "SafeJSC",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "SafeJSC", targets: ["SafeJSC"]),
    ],
    targets: [
        .target(name: "CJSCKeepAlive", path: "CJSCKeepAlive"),
        .target(name: "SafeJSC", dependencies: ["CJSCKeepAlive"], path: "SafeJSC", swiftSettings: settings,
                linkerSettings: [.linkedFramework("JavaScriptCore")]),
    ]
)
