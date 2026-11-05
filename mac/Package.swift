// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MeetingRecorder", path: "Sources/MeetingRecorder"),
    ]
)
