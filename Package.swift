// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode (strict concurrency) is the default with tools 6.2. The only dependency is AppSupportKit,
// which backs DiagnosticLogPreference.
let package = Package(
    name: "DiagnosticsKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Overlabing/AppSupportKit", exact: "0.1.1")
    ],
    targets: [
        .target(name: "DiagnosticsKit", dependencies: [.product(name: "Preferences", package: "AppSupportKit")]),
        .testTarget(name: "DiagnosticsKitTests", dependencies: ["DiagnosticsKit"]),
    ]
)
