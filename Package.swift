// swift-tools-version: 5.9
import PackageDescription
import Foundation

let privacyPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "WalkingPadController",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WalkingPadController", targets: ["WalkingPadController"])
    ],
    targets: [
        .executableTarget(
            name: "WalkingPadController",
            path: "Sources/WalkingPadController",
            // A Swift package executable has no app bundle; embed its privacy description.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", privacyPlist
            ])]
        ),
        .testTarget(
            name: "WalkingPadControllerTests",
            dependencies: ["WalkingPadController"],
            path: "Tests/WalkingPadControllerTests"
        )
    ]
)
