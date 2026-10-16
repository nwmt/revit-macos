// swift-tools-version:6.0
// The menu bar app (for now a stub that checks its own bundle). app/build.sh builds it; app/make-bundle.sh puts it in
// <App>.app. The minimum macOS must equal APP_MIN_MACOS in app/app.conf: app/sign.sh refuses a binary built for a newer one.
import PackageDescription

let package = Package(
    name: "AppMain",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "AppMain", path: "Sources/AppMain")]
)
