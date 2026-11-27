import Foundation
import SwiftUI
import WebKit
import ObjectiveC

// Wraps a `_WKFeature` (private SPI on WKPreferences) into a Swift value type
// so the rest of the app can list/categorize/toggle WebKit features without
// touching ObjC runtime code directly.
struct WebKitFeature: Identifiable, Hashable {
    enum Status: Int, Hashable {
        case embedder = 0
        case unstable = 1
        case internalUse = 2
        case developer = 3
        case testable = 4
        case preview = 5
        case stable = 6
        case mature = 7
        case unknown = -1

        init(rawInt: Int) {
            self = Status(rawValue: rawInt) ?? .unknown
        }

        var label: String {
            switch self {
            case .embedder: return "Embedder"
            case .unstable: return "Unstable"
            case .internalUse: return "Internal"
            case .developer: return "Developer"
            case .testable: return "Testable"
            case .preview: return "Preview"
            case .stable: return "Stable"
            case .mature: return "Mature"
            case .unknown: return "Other"
            }
        }

        var color: Color {
            switch self {
            case .stable, .mature: return .green
            case .preview: return .blue
            case .testable: return .orange
            case .developer, .internalUse, .embedder: return .gray
            case .unstable: return .red
            case .unknown: return .secondary
            }
        }
    }

    let key: String
    let name: String
    let details: String
    let category: String
    let status: Status
    let defaultValue: Bool

    var id: String { key }
}

// One-shot registry that resolves WKPreferences `_features` SPI and exposes
// a Swift-friendly view of every available WebKit feature. The raw `_WKFeature`
// NSObject is cached alongside so callers that need to apply overrides via
// `_setEnabled:forFeature:` can fetch it without re-querying the SPI.
enum WebKitFeatureRegistry {
    static let allFeatures: [WebKitFeature] = loadAllFeatures()

    static let byCategory: [(category: String, features: [WebKitFeature])] = {
        let grouped = Dictionary(grouping: allFeatures, by: { $0.category })
        return grouped
            .map { (category: $0.key, features: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }()

    static func rawFeature(forKey key: String) -> NSObject? {
        rawFeaturesByKey[key]
    }

    private static let rawFeaturesByKey: [String: NSObject] = loadRawFeatures()

    private static func loadRawFeatures() -> [String: NSObject] {
        guard let features = fetchFeatureObjects() else { return [:] }
        return Dictionary(uniqueKeysWithValues: features.compactMap { feature in
            (feature.value(forKey: "key") as? String).map { ($0, feature) }
        })
    }

    private static func loadAllFeatures() -> [WebKitFeature] {
        guard let features = fetchFeatureObjects() else { return [] }
        if let probe = features.first {
            Self.logAvailableProperties(of: probe)
        }
        return features.compactMap { Self.makeFeature(from: $0) }
    }

    // One-time dump of every property exposed on _WKFeature so we can adapt
    // when the SPI shape changes between WebKit versions. Visible in Console
    // under the WebView category.
    private static func logAvailableProperties(of object: NSObject) {
        let cls: AnyClass = type(of: object)
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else { return }
        defer { free(list) }
        var names: [String] = []
        for i in 0..<Int(count) {
            let prop = list[i]
            names.append(String(cString: property_getName(prop)))
        }
        logInfo(.webView, "_WKFeature properties: \(names.sorted().joined(separator: ", "))")
    }

    private static func fetchFeatureObjects() -> [NSObject]? {
        typealias GetFeaturesIMP = @convention(c) (AnyClass, Selector) -> NSArray?
        let getSel = Selector(("_features"))
        guard let classMethod = class_getClassMethod(WKPreferences.self, getSel) else {
            logError(.webView, "WKPreferences _features SPI unavailable; cannot enumerate WebKit features")
            return nil
        }
        let getFeatures = unsafeBitCast(method_getImplementation(classMethod), to: GetFeaturesIMP.self)
        guard let raw = getFeatures(WKPreferences.self, getSel) as? [NSObject] else {
            logError(.webView, "WKPreferences _features returned nil or wrong type")
            return nil
        }
        return raw
    }

    private static func makeFeature(from raw: NSObject) -> WebKitFeature? {
        guard let key = safeValue(raw, key: "key") as? String else { return nil }
        let name = (safeValue(raw, key: "name") as? String) ?? key
        let details = (safeValue(raw, key: "details") as? String) ?? ""
        let statusRaw = (safeValue(raw, key: "status") as? Int) ?? -1
        let defaultValue = (safeValue(raw, key: "defaultValue") as? Bool) ?? false
        let category = resolveCategory(from: raw)

        return WebKitFeature(
            key: key,
            name: name,
            details: details,
            category: category,
            status: WebKitFeature.Status(rawInt: statusRaw),
            defaultValue: defaultValue
        )
    }

    // KVC `value(forKey:)` raises NSUnknownKeyException for keys the object
    // doesn't expose. Guard with `responds(to:)` so we can probe optional
    // properties without crashing when WebKit renames or removes them.
    private static func safeValue(_ object: NSObject, key: String) -> Any? {
        guard object.responds(to: Selector(key)) else { return nil }
        return object.value(forKey: key)
    }

    // _WKFeature.category is an `_WKFeatureCategory` enum (NSInteger). Some
    // WebKit builds also expose a string variant — try those first; fall back
    // to mapping the enum index to a human-readable name.
    private static func resolveCategory(from raw: NSObject) -> String {
        if let str = safeValue(raw, key: "categoryString") as? String, !str.isEmpty {
            return str
        }
        if let str = safeValue(raw, key: "categoryName") as? String, !str.isEmpty {
            return str
        }
        if let str = safeValue(raw, key: "category") as? String, !str.isEmpty {
            return str
        }
        if let index = safeValue(raw, key: "category") as? Int {
            return categoryName(forIndex: index)
        }
        return "Other"
    }

    // Mirrors `_WKFeatureCategory` declaration order in WebKit's _WKFeature.h
    // as of WebKit 26.x. If a future WebKit reorders or extends this enum, the
    // category names will drift — adjust here.
    private static let categoryNames: [String] = [
        "None",            // _WKFeatureCategoryNone
        "Animation",       // _WKFeatureCategoryAnimation
        "CSS",             // _WKFeatureCategoryCSS
        "DOM",             // _WKFeatureCategoryDOM
        "Extensions",      // _WKFeatureCategoryExtensions
        "HTML",            // _WKFeatureCategoryHTML
        "HTTP",            // _WKFeatureCategoryHTTP
        "Hardware",        // _WKFeatureCategoryHardware
        "JavaScript",      // _WKFeatureCategoryJavaScript
        "Layout",          // _WKFeatureCategoryLayout
        "Logging",         // _WKFeatureCategoryLogging
        "Media",           // _WKFeatureCategoryMedia
        "Network",         // _WKFeatureCategoryNetwork
        "Performance",     // _WKFeatureCategoryPerformance
        "Privacy",         // _WKFeatureCategoryPrivacy
        "SVG",             // _WKFeatureCategorySVG
        "Security",        // _WKFeatureCategorySecurity
        "WebRTC",          // _WKFeatureCategoryWebRTC
        "WebXR",           // _WKFeatureCategoryWebXR
        "WebGPU",          // _WKFeatureCategoryWebGPU
        "WebAssembly",     // _WKFeatureCategoryWebAssembly
        "Service Worker",  // _WKFeatureCategoryServiceWorker
        "Accessibility",   // _WKFeatureCategoryAccessibility
        "Other"            // _WKFeatureCategoryOther
    ]

    private static func categoryName(forIndex index: Int) -> String {
        guard index >= 0 && index < categoryNames.count else { return "Other" }
        return categoryNames[index]
    }
}
