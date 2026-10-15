// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // "Translate into": runs the optional Gemma 4 / EuroLLM download on this Mac. No traits — the FoundationModels
        // bridge needs a newer SDK and Murmur doesn't use it.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "WhisperCppFramework",
            path: "Vendor/whisper.xcframework"
        ),
        .binaryTarget(
            name: "HarperFramework",
            path: "Vendor/harper.xcframework"
        ),
        .binaryTarget(
            name: "SherpaOnnxFramework",
            path: "Vendor/sherpa-onnx.xcframework"
        ),
        .target(
            name: "CMurmurSherpa",
            dependencies: ["SherpaOnnxFramework"],
            path: "Sources/CMurmurSherpa"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "WhisperCppFramework",
                "HarperFramework",
                "SherpaOnnxFramework",
                "CMurmurSherpa",
            ],
            path: "Sources/Murmur",
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Words"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
