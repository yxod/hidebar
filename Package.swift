// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HideBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HideBar",
            path: "Sources/HideBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
