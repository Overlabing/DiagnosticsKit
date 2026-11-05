// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode (strict concurrency) is the default with tools 6.2. The only dependency is AppSupportKit,
// which backs DiagnosticLogPreference. Kits depend on each other by patch range and apps pin exact: an app's exact
// AppSupportKit pin resolves inside this range, and a new AppSupportKit patch never forces a release of this kit.
let package = Package(
    name: "DiagnosticsKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Overlabing/AppSupportKit", .upToNextMinor(from: "0.1.1"))
    ],
    targets: [
        .target(name: "DiagnosticsKit", dependencies: [.product(name: "Preferences", package: "AppSupportKit")]),
        .testTarget(name: "DiagnosticsKitTests", dependencies: ["DiagnosticsKit"]),
    ]
)
