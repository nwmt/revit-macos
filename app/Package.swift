// swift-tools-version:6.0
// The menu bar app. AppCore holds everything that can be tested without a screen (the engine's events and JSON, the
// processes, the models); AppMain holds the SwiftUI scenes and views. app/build.sh builds the product AppMain;
// app/make-bundle.sh puts it in <App>.app. app/test.sh runs AppCoreTests. The minimum macOS must equal APP_MIN_MACOS
// in app/app.conf: app/sign.sh refuses a binary built for a newer one.
import PackageDescription

let package = Package(
    name: "AppMain",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AppCore", path: "Sources/AppCore"),
        .executableTarget(name: "AppMain", dependencies: ["AppCore"], path: "Sources/AppMain"),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"], path: "Tests/AppCoreTests", exclude: ["Fixtures"]),
        // a test helper (app/test.sh builds it): starts a run as the app does and exits at once; not in the bundle
        .executableTarget(name: "SpawnProbe", dependencies: ["AppCore"], path: "Tests/SpawnProbe"),
    ]
)
