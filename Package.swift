// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SuperVoiceAssistant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SuperVoiceAssistant",
            targets: ["SuperVoiceAssistant"]),
        .executable(
            name: "TestAudioCollector",
            targets: ["TestAudioCollector"]),
        .executable(
            name: "TestStreamingTTS",
            targets: ["TestStreamingTTS"]),
        .executable(
            name: "TestSentenceSplitter",
            targets: ["TestSentenceSplitter"]),
        .executable(
            name: "TestOpenAITranscription",
            targets: ["TestOpenAITranscription"]),
        .executable(
            name: "TestTextInserter",
            targets: ["TestTextInserter"]),
        .executable(
            name: "RecordScreen",
            targets: ["RecordScreen"]),
        .executable(
            name: "TranscribeVideo",
            targets: ["TranscribeVideo"]),
        .library(
            name: "SharedModels",
            targets: ["SharedModels"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.8.0"),
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "SharedModels",
            dependencies: [
                .product(name: "SwiftDotenv", package: "swift-dotenv")
            ],
            path: "SharedSources"),
        .executableTarget(
            name: "SuperVoiceAssistant",
            dependencies: ["KeyboardShortcuts", "SharedModels"],
            path: "Sources",
            resources: [
                .copy("Assets.xcassets"),
                .copy("AppIcon.icns")
            ]),
        .executableTarget(
            name: "TestAudioCollector",
            dependencies: ["SharedModels"],
            path: "tests/test-audio-collector"),
        .executableTarget(
            name: "TestStreamingTTS",
            dependencies: ["SharedModels"],
            path: "tests/test-streaming-tts"),
        .executableTarget(
            name: "TestSentenceSplitter",
            dependencies: ["SharedModels"],
            path: "tests/test-sentence-splitter"),
        .executableTarget(
            name: "TestOpenAITranscription",
            dependencies: [],
            path: "tests/test-openai-transcription"),
        .executableTarget(
            name: "TestTextInserter",
            dependencies: ["SharedModels"],
            path: "tests/test-text-inserter"),
        .executableTarget(
            name: "RecordScreen",
            dependencies: [],
            path: "tools/record-screen"),
        .executableTarget(
            name: "TranscribeVideo",
            dependencies: [],
            path: "tools/transcribe-video")
    ]
)
