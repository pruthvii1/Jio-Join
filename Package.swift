// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JioJoinMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "JioJoinMac", targets: ["JioJoinMac"])],
    targets: [
        .executableTarget(
            name: "JioJoinMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(name: "JioJoinMacTests", dependencies: ["JioJoinMac"])
    ],
    swiftLanguageModes: [.v5]
)
