// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bigbro-kit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BigBroKit", targets: ["BigBroKit"])
    ],
    targets: [
        .target(
            name: "BigBroKit",
            path: "Sources"
        )
    ]
)
