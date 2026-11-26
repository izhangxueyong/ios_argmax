// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let package = Package(
    name: "argmax-oss-swift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "ArgmaxOSS",
            targets: ["ArgmaxOSS"]
        ),
        .library(
            name: "WhisperKit",
            targets: ["WhisperKit"]
        ),
        .library(
            name: "TTSKit",
            targets: ["TTSKit"]
        ),
        .library(
            name: "SpeakerKit",
            targets: ["SpeakerKit"]
        ),
        // On-device VAD / speaker verification / SenseVoice / text embedding
        // used by the AutoTranscribe example app.
        .library(
            name: "AutoTranscribeAI",
            targets: ["AutoTranscribeAI"]
        ),
        // xtool entry point: xtool wraps a SwiftPM *library* product into an
        // iOS .app. The Xcode project still compiles the same sources directly,
        // so adding this product does not change the xcodebuild/CI path.
        .library(
            name: "AutoTranscribeApp",
            targets: ["AutoTranscribeApp"]
        ),
        .executable(
            name: "argmax-cli",
            targets: ["ArgmaxCLI"]
        ),
        .executable(
            name: "whisperkit-cli",
            targets: ["ArgmaxCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // sherpa-onnx XCFrameworks (iOS + simulator): SenseVoice, Silero VAD
        // and CAMPPlus speaker embedding all share this one ONNX runtime.
        .package(url: "https://github.com/willwade/sherpa-onnx-spm.git", exact: "1.13.16"),
    ] + (isServerEnabled() ? [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.1"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.2"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.2"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor", from: "1.0.1"),

    ] : []),
    targets: [
        .target(
            name: "ArgmaxOSS",
            dependencies: [
                "ArgmaxCore",
                "WhisperKit",
                "TTSKit",
                "SpeakerKit",
            ],
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "ArgmaxCore",
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "WhisperKit",
            dependencies: [
                "ArgmaxCore",
            ],
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "TTSKit",
            dependencies: [
                "ArgmaxCore",
            ],
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "SpeakerKit",
            dependencies: [
                "ArgmaxCore",
                "WhisperKit",
            ],
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "AutoTranscribeAI",
            dependencies: [
                .product(name: "SherpaOnnx", package: "sherpa-onnx-spm"),
            ],
            path: "Examples/AutoTranscribe/AutoTranscribeAI"
        ),
        // Same app sources as AutoTranscribe.xcodeproj. SwiftPM resources keep
        // the `Models/...` and `Resources/...` layout; BundledResources resolves
        // them inside the generated resource bundle on xtool builds.
        .target(
            name: "AutoTranscribeApp",
            dependencies: [
                "WhisperKit",
                "AutoTranscribeAI",
            ],
            path: "Examples/AutoTranscribe/AutoTranscribe",
            resources: [
                .copy("Models"),
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "ArgmaxCoreTests",
            dependencies: [
                "ArgmaxCore",
            ],
            resources: [
                .process("External/Resources"),
            ],
            swiftSettings: swiftSettings()
        ),
        .testTarget(
            name: "WhisperKitTests",
            dependencies: [
                "WhisperKit",
            ],
            exclude: ["UnitTestsPlan.xctestplan"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swiftSettings()
        ),
        .testTarget(
            name: "TTSKitTests",
            dependencies: [
                "TTSKit"
            ],
            swiftSettings: swiftSettings()
        ),
        .testTarget(
            name: "SpeakerKitTests",
            dependencies: [
                "SpeakerKit",
                "WhisperKit",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swiftSettings()
        ),
        .executableTarget(
            name: "ArgmaxCLI",
            dependencies: [
                "WhisperKit",
                "TTSKit",
                "SpeakerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ] + (isServerEnabled() ? [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
            ] : []),
            path: "Sources/ArgmaxCLI",
            exclude: (isServerEnabled() ? [] : ["Server"]),
            swiftSettings: swiftSettings() + (isServerEnabled() ? [.define("BUILD_SERVER_CLI")] : [])
        )
    ],
    swiftLanguageVersions: [.v5]
)

func isServerEnabled() -> Bool {
    if let enabledValue = Context.environment["BUILD_ALL"] {
        return enabledValue.lowercased() == "true" || enabledValue == "1"
    }

    // Default disabled, change to true temporarily for local development
    return false
}

func swiftSettings() -> [SwiftSetting] {
    [.enableExperimentalFeature("StrictConcurrency")]
}
