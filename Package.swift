// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "ACarousel",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(
            name: "ACarousel",
            targets: ["ACarousel"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ACarousel",
            dependencies: []),
        .testTarget(
            name: "ACarouselTests",
            dependencies: ["ACarousel"])
    ]
)
