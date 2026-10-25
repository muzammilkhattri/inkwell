// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Inkwell",
            path: "Sources/Inkwell",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("WebKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
