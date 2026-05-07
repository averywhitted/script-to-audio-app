// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TableRead",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TableRead", targets: ["ScriptAudioDramaApp"])
    ],
    targets: [
        .executableTarget(
            name: "ScriptAudioDramaApp",
            path: "Sources/ScriptAudioDramaApp"
        )
    ]
)
