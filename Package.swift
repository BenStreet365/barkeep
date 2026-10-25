// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "barkeep",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "barkeep", targets: ["barkeep"]),
        // Not "Barkeep": it would collide with "barkeep" on a case-insensitive disk. Scripts/build.sh
        // wraps it in Barkeep.app.
        .executable(name: "BarkeepApp", targets: ["BarkeepApp"]),
    ],
    targets: [
        .target(
            name: "BarkeepCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "barkeep",
            dependencies: ["BarkeepCore"],
            linkerSettings: [
                // Embeds the bundle identifier (uk.street365.barkeep) and version in the binary.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist"]),
            ]
        ),
        .executableTarget(
            name: "BarkeepApp",
            dependencies: ["BarkeepCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "BarkeepCoreTests",
            dependencies: ["BarkeepCore"]
        ),
    ]
)
