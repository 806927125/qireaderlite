// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LegadoEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LegadoEngine", targets: ["LegadoEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "5.2.7"),
    ],
    targets: [
        .target(
            name: "LegadoEngine",
            dependencies: ["SwiftSoup", "Kanna"],
            resources: [.copy("JS/Resources")]
        ),
        .testTarget(name: "LegadoEngineTests", dependencies: ["LegadoEngine"]),
    ]
)