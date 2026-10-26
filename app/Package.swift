// swift-tools-version:6.0
// The menu bar app. AppCore holds everything that can be tested without a screen (the engine's events and JSON, the
// processes, the models); AppMain holds the SwiftUI scenes and views. app/build.sh builds the product AppMain;
// app/make-bundle.sh puts it in <App>.app. app/test.sh runs AppCoreTests. The minimum macOS must equal APP_MIN_MACOS
// in app/app.conf: app/sign.sh refuses a binary built for a newer one.
import PackageDescription

let package = Package(
    name: "AppMain",
    platforms: [.macOS("27.0")],
    targets: [
        // the trackpad helper's state file and arguments: the one format the app and the helper share
        .target(name: "TrackpadState", path: "Sources/TrackpadState"),
        // the trackpad gestures' logic without system calls: hittest's protocol, the coordinate scale, the view rule
        .target(name: "TrackpadCore", path: "Sources/TrackpadCore"),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"], path: "Tests/TrackpadCoreTests"),
        // processes and files of the trackpad helper: the hittest client, its log, the coordinator
        .target(name: "TrackpadIO", dependencies: ["TrackpadCore", "TrackpadState"], path: "Sources/TrackpadIO"),
        .testTarget(name: "TrackpadIOTests", dependencies: ["TrackpadIO", "TrackpadCore", "TrackpadState"],
                    path: "Tests/TrackpadIOTests", exclude: ["Fixtures"]),
        // <App> Trackpad.app: the event tap and its system glue (app/make-bundle.sh puts it in Contents/Helpers)
        .executableTarget(name: "TrackpadHelper", dependencies: ["TrackpadCore", "TrackpadIO", "TrackpadState"],
                          path: "Sources/TrackpadHelper"),
        .target(name: "AppCore", dependencies: ["TrackpadState"], path: "Sources/AppCore"),
        .executableTarget(name: "AppMain", dependencies: ["AppCore"], path: "Sources/AppMain"),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "TrackpadState"], path: "Tests/AppCoreTests", exclude: ["Fixtures"]),
        // a test helper (app/test.sh builds it): starts a run as the app does and exits at once; not in the bundle
        .executableTarget(name: "SpawnProbe", dependencies: ["AppCore"], path: "Tests/SpawnProbe"),
    ]
)
