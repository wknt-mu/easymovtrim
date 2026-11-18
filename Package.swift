// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EasyMovTrim",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EasyMovTrim",
            path: "Sources/EasyMovTrim"
        )
    ]
)
