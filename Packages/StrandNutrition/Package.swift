// swift-tools-version:5.9
import PackageDescription

// Pure nutrition logic for the macro logger: value types, portion math, the plausibility rule and
// the Open Food Facts / Claude reply decoders. Foundation only, so it builds and tests on Linux.
let package = Package(
    name: "StrandNutrition",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandNutrition", targets: ["StrandNutrition"])],
    targets: [
        .target(name: "StrandNutrition"),
        .testTarget(name: "StrandNutritionTests", dependencies: ["StrandNutrition"]),
    ]
)
