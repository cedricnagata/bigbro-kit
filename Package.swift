// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BigBroKit",
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
                "Discovery/BonjourBrowser.swift",
                "Networking/BigBroAPIClient.swift",
                "Storage/KeychainTokenStore.swift",
                "UI/BigBroChatView.swift"
            ]
        )
    ]
)
