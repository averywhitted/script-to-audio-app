// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScriptAudioDrama",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScriptAudioDrama", targets: ["ScriptAudioDramaApp"])
    ],
    targets: [
        .executableTarget(
            name: "ScriptAudioDramaApp",
            path: "Sources/ScriptAudioDramaApp"
        )
    ]
)
