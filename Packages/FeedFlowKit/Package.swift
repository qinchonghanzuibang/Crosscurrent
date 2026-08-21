// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeedFlowKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeedFlowDomain", targets: ["FeedFlowDomain"]),
        .library(name: "FeedFlowStorage", targets: ["FeedFlowStorage"]),
        .library(name: "FeedFlowConnectors", targets: ["FeedFlowConnectors"]),
        .library(name: "FeedFlowBrowser", targets: ["FeedFlowBrowser"]),
        .library(name: "FeedFlowIngestion", targets: ["FeedFlowIngestion"]),
        .library(name: "FeedFlowIntelligence", targets: ["FeedFlowIntelligence"]),
        .library(name: "FeedFlowSearch", targets: ["FeedFlowSearch"]),
        .library(name: "FeedFlowModels", targets: ["FeedFlowModels"]),
        .library(name: "FeedFlowReader", targets: ["FeedFlowReader"]),
        .library(name: "FeedFlowRanking", targets: ["FeedFlowRanking"]),
        .library(name: "FeedFlowDesignSystem", targets: ["FeedFlowDesignSystem"]),
        .library(name: "FeedFlowIPC", targets: ["FeedFlowIPC"]),
        .library(name: "FeedFlowDiagnostics", targets: ["FeedFlowDiagnostics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/nmdias/FeedKit.git", exact: "10.4.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7"),
        .package(url: "https://github.com/unum-cloud/USearch.git", exact: "2.26.0"),
        .package(url: "https://github.com/Ryu0118/swift-readability.git", exact: "0.3.0"),
    ],
    targets: [
        .target(name: "FeedFlowDomain"),
        .target(name: "FeedFlowDiagnostics", dependencies: ["FeedFlowDomain"]),
        .target(name: "FeedFlowIPC", dependencies: ["FeedFlowDomain"]),
        .target(name: "FeedFlowStorage", dependencies: [
            "FeedFlowDomain", "FeedFlowDiagnostics",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "FeedFlowConnectors", dependencies: [
            "FeedFlowDomain", "FeedFlowDiagnostics",
            .product(name: "FeedKit", package: "FeedKit"),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "FeedFlowBrowser", dependencies: [
            "FeedFlowDomain", "FeedFlowIPC", "FeedFlowConnectors",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "Readability", package: "swift-readability"),
        ]),
        .target(name: "FeedFlowIngestion", dependencies: ["FeedFlowDomain", "FeedFlowStorage", "FeedFlowConnectors", "FeedFlowBrowser"]),
        .target(name: "FeedFlowIntelligence", dependencies: ["FeedFlowDomain", "FeedFlowStorage"]),
        .target(name: "FeedFlowSearch", dependencies: [
            "FeedFlowDomain", "FeedFlowStorage",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "USearch", package: "USearch"),
        ]),
        .target(name: "FeedFlowRanking", dependencies: ["FeedFlowDomain", "FeedFlowStorage"]),
        .target(name: "FeedFlowReader", dependencies: ["FeedFlowDomain", "FeedFlowBrowser"]),
        .target(name: "FeedFlowModels", dependencies: ["FeedFlowDomain", "FeedFlowRanking"]),
        .target(name: "FeedFlowDesignSystem", dependencies: ["FeedFlowDomain"]),
        .testTarget(name: "FeedFlowDomainTests", dependencies: ["FeedFlowDomain", "FeedFlowConnectors", "FeedFlowIngestion", "FeedFlowIntelligence", "FeedFlowModels", "FeedFlowRanking", "FeedFlowSearch", "FeedFlowStorage"]),
        .testTarget(name: "FeedFlowStorageTests", dependencies: ["FeedFlowStorage", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "FeedFlowConnectorTests", dependencies: ["FeedFlowConnectors", "FeedFlowDomain"]),
        .testTarget(name: "FeedFlowBrowserTests", dependencies: ["FeedFlowBrowser", "FeedFlowReader"]),
        .testTarget(name: "FeedFlowIPCTests", dependencies: ["FeedFlowIPC"]),
    ]
)
