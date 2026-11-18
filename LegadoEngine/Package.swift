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
        // ⭐⭐⭐⭐⭐ **swift-crypto**（2026-11-19 CI build296 实证）
        //   `JS/JSNatives.swift` 里 `import Crypto` ⇒ Apple 平台上 `Crypto` **不是系统模块**
        //   （Apple 只有 `CryptoKit`）⇒ **不声明这个依赖 ⇒ iOS 编译必挂**：
        //   `error: Unable to find module dependency: 'Crypto'` ⭐⭐⭐
        //   ⇒ swift-crypto 在 Apple 平台上就是 CryptoKit 的再导出（模块名仍是 `Crypto`）⭐⭐⭐
        //   ⚠️ Linux 侧**编不到**这个文件（`#if canImport(JavaScriptCore) && !os(Linux)`）
        //   ⇒ **沙盒 Linux 门禁抓不到这个错** ⇒ 只能靠 CI ⇒ ⇒ 必须有静态门禁兜底 ⭐⭐⭐
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "LegadoEngine",
            dependencies: [
                "SwiftSoup",
                "Kanna",
                // ⭐ `Crypto`（swift-crypto 的 product 名就是 `Crypto`）
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("JS/Resources")]
        ),
        .testTarget(name: "LegadoEngineTests", dependencies: ["LegadoEngine"]),
    ]
)