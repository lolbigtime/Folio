// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Folio",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Folio",
            targets: ["Folio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.26.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Folio",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "FolioTests", dependencies: ["Folio"], resources: [.process("Fixtures")])
    ]
)
