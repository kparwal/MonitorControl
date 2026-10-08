// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "monitorctl",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "monitorctl", targets: ["monitorctl"]),
        .executable(name: "MonitorControl", targets: ["MonitorControl"]),
    ],
    targets: [
        .target(name: "DDC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]),
        .executableTarget(name: "monitorctl", dependencies: ["DDC"]),
        .executableTarget(name: "MonitorControl", dependencies: ["DDC"]),
    ]
)
