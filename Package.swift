// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jpg2heif",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ConversionKit", path: "Sources/ConversionKit"),
        .executableTarget(name: "heifconv", dependencies: ["ConversionKit"], path: "Sources/heifconv"),
    ]
)
