// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CrosscurrentKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CrosscurrentDomain", targets: ["CrosscurrentDomain"]),
        .library(name: "CrosscurrentStorage", targets: ["CrosscurrentStorage"]),
        .library(name: "CrosscurrentConnectors", targets: ["CrosscurrentConnectors"]),
        .library(name: "CrosscurrentBrowser", targets: ["CrosscurrentBrowser"]),
        .library(name: "CrosscurrentIngestion", targets: ["CrosscurrentIngestion"]),
        .library(name: "CrosscurrentIntelligence", targets: ["CrosscurrentIntelligence"]),
        .library(name: "CrosscurrentSearch", targets: ["CrosscurrentSearch"]),
        .library(name: "CrosscurrentModels", targets: ["CrosscurrentModels"]),
        .library(name: "CrosscurrentReader", targets: ["CrosscurrentReader"]),
        .library(name: "CrosscurrentRanking", targets: ["CrosscurrentRanking"]),
        .library(name: "CrosscurrentDesignSystem", targets: ["CrosscurrentDesignSystem"]),
        .library(name: "CrosscurrentIPC", targets: ["CrosscurrentIPC"]),
        .library(name: "CrosscurrentDiagnostics", targets: ["CrosscurrentDiagnostics"]),
        // Qualification-only products. The app must not link a runtime until the
        // joint model/runtime evidence selects a shipping pair.
        .library(name: "CrosscurrentEmbeddingQualification", targets: ["CrosscurrentEmbeddingQualification"]),
        .library(name: "CrosscurrentEmbeddingCoreML", targets: ["CrosscurrentEmbeddingCoreML"]),
        .library(name: "CrosscurrentEmbeddingMLX", targets: ["CrosscurrentEmbeddingMLX"]),
        .library(name: "CrosscurrentEmbeddingORT", targets: ["CrosscurrentEmbeddingORT"]),
        .executable(name: "crosscurrent-qualification", targets: ["CrosscurrentQualification"]),
        .executable(name: "crosscurrent-embedding-coreml-benchmark", targets: ["CrosscurrentEmbeddingCoreMLBenchmark"]),
        .executable(name: "crosscurrent-embedding-mlx-benchmark", targets: ["CrosscurrentEmbeddingMLXBenchmark"]),
        .executable(name: "crosscurrent-embedding-ort-benchmark", targets: ["CrosscurrentEmbeddingORTBenchmark"]),
        .executable(name: "crosscurrent-model-artifacts", targets: ["CrosscurrentModelArtifacts"]),
        .executable(name: "crosscurrent-ort-shim-builder", targets: ["CrosscurrentORTShimBuilder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/nmdias/FeedKit.git", exact: "10.4.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7"),
        .package(url: "https://github.com/unum-cloud/USearch.git", exact: "2.26.0"),
        .package(url: "https://github.com/Ryu0118/swift-readability.git", exact: "0.3.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
    ],
    targets: [
        .target(name: "CrosscurrentDomain"),
        .target(name: "CrosscurrentDiagnostics", dependencies: ["CrosscurrentDomain"]),
        .target(name: "CrosscurrentIPC", dependencies: ["CrosscurrentDomain"]),
        .target(name: "CrosscurrentStorage", dependencies: [
            "CrosscurrentDomain", "CrosscurrentDiagnostics",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "CrosscurrentConnectors", dependencies: [
            "CrosscurrentDomain", "CrosscurrentDiagnostics",
            .product(name: "FeedKit", package: "FeedKit"),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "CrosscurrentBrowser", dependencies: [
            "CrosscurrentDomain", "CrosscurrentIPC", "CrosscurrentConnectors",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "Readability", package: "swift-readability"),
        ]),
        .target(name: "CrosscurrentIngestion", dependencies: ["CrosscurrentDomain", "CrosscurrentStorage", "CrosscurrentConnectors", "CrosscurrentBrowser"]),
        .target(name: "CrosscurrentIntelligence", dependencies: ["CrosscurrentDomain", "CrosscurrentStorage"]),
        .target(name: "CrosscurrentSearch", dependencies: [
            "CrosscurrentDomain", "CrosscurrentStorage",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "USearch", package: "USearch"),
        ]),
        .target(name: "CrosscurrentRanking", dependencies: ["CrosscurrentDomain", "CrosscurrentStorage"]),
        .target(name: "CrosscurrentReader", dependencies: ["CrosscurrentDomain", "CrosscurrentBrowser"]),
        .target(name: "CrosscurrentModels", dependencies: ["CrosscurrentDomain", "CrosscurrentRanking"]),
        .target(name: "CrosscurrentDesignSystem", dependencies: ["CrosscurrentDomain"]),
        .target(name: "CrosscurrentEmbeddingQualification", dependencies: ["CrosscurrentDomain", "CrosscurrentStorage"]),
        .target(name: "CrosscurrentEmbeddingCoreML", dependencies: [
            "CrosscurrentEmbeddingQualification",
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "CrosscurrentEmbeddingMLX", dependencies: [
            "CrosscurrentEmbeddingQualification",
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .target(name: "CrosscurrentEmbeddingORT", dependencies: [
            "CrosscurrentEmbeddingQualification", "CrosscurrentSearch",
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .executableTarget(name: "CrosscurrentQualification", dependencies: [
            "CrosscurrentDomain", "CrosscurrentStorage", "CrosscurrentConnectors",
            "CrosscurrentIngestion", "CrosscurrentIntelligence", "CrosscurrentRanking",
            "CrosscurrentSearch",
        ]),
        .executableTarget(name: "CrosscurrentEmbeddingCoreMLBenchmark", dependencies: [
            "CrosscurrentEmbeddingQualification", "CrosscurrentEmbeddingCoreML",
        ]),
        .executableTarget(name: "CrosscurrentEmbeddingMLXBenchmark", dependencies: [
            "CrosscurrentEmbeddingQualification", "CrosscurrentEmbeddingMLX",
        ]),
        .executableTarget(name: "CrosscurrentEmbeddingORTBenchmark", dependencies: [
            "CrosscurrentEmbeddingQualification", "CrosscurrentEmbeddingORT",
        ]),
        .executableTarget(name: "CrosscurrentModelArtifacts"),
        .executableTarget(name: "CrosscurrentORTShimBuilder"),
        .testTarget(name: "CrosscurrentDomainTests", dependencies: ["CrosscurrentDomain", "CrosscurrentConnectors", "CrosscurrentIngestion", "CrosscurrentIntelligence", "CrosscurrentModels", "CrosscurrentRanking", "CrosscurrentSearch", "CrosscurrentStorage"]),
        .testTarget(name: "CrosscurrentStorageTests", dependencies: [
            "CrosscurrentConnectors", "CrosscurrentIngestion", "CrosscurrentStorage",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "CrosscurrentConnectorTests", dependencies: ["CrosscurrentConnectors", "CrosscurrentDomain"]),
        .testTarget(name: "CrosscurrentBrowserTests", dependencies: ["CrosscurrentBrowser", "CrosscurrentReader"]),
        .testTarget(name: "CrosscurrentIPCTests", dependencies: ["CrosscurrentIPC"]),
    ]
)
