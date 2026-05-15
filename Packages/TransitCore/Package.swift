// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransitCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "TransitModels", targets: ["TransitModels"]),
        .library(name: "TransitAPI", targets: ["TransitAPI"]),
        .library(name: "TransitCache", targets: ["TransitCache"]),
        .library(name: "TransitLocation", targets: ["TransitLocation"]),
        .library(name: "TransitDomain", targets: ["TransitDomain"]),
        .library(name: "ChicagoTheme", targets: ["ChicagoTheme"]),
        .library(name: "TransitUI", targets: ["TransitUI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TransitModels",
            resources: [.process("Resources")]
        ),
        .target(
            name: "TransitAPI",
            dependencies: ["TransitModels"]
        ),
        .target(
            name: "TransitCache",
            dependencies: ["TransitModels"]
        ),
        .target(
            name: "TransitLocation",
            dependencies: ["TransitModels"]
        ),
        .target(
            name: "TransitDomain",
            dependencies: ["TransitModels", "TransitCache", "TransitLocation"]
        ),
        .target(
            name: "ChicagoTheme",
            dependencies: ["TransitModels"],
            // Fonts are .copy so they ship verbatim. `.process("Resources")`
            // alone caused CTFontManagerRegisterFontsForURL to fail at
            // launch — TTFs were flattened and the lookup couldn't find
            // them. The asset catalog still needs .process so it's compiled.
            resources: [
                .process("Resources/ChicagoColors.xcassets"),
                .copy("Resources/Fonts"),
            ]
        ),
        .target(
            name: "TransitUI",
            dependencies: ["TransitModels", "TransitDomain", "ChicagoTheme"]
        ),
        .testTarget(
            name: "TransitModelsTests",
            dependencies: ["TransitModels"]
        ),
        .testTarget(
            name: "TransitAPITests",
            dependencies: ["TransitAPI"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TransitCacheTests",
            dependencies: ["TransitCache"]
        ),
        .testTarget(
            name: "TransitDomainTests",
            dependencies: ["TransitDomain"]
        ),
        .testTarget(
            name: "TransitLocationTests",
            dependencies: ["TransitLocation"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
