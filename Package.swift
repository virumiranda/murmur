// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("13.3")],
    targets: [
        // Prebuilt whisper.cpp (v1.9.4, build b5130) with Metal. Pinned by checksum.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["whisper"],
            path: "Sources/Murmur",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
