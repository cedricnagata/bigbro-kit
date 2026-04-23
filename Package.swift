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
            path: ".",
            sources: [
                "bigbro/BigBroClient.swift",
                "Models/BigBroDevice.swift",
                "Models/Message.swift",
                "Models/Tool.swift",
                "Discovery/BonjourBrowser.swift",
                "Networking/PeerConnection.swift",
            ]
        )
    ]
)
