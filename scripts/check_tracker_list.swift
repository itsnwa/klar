// Compiles a tracker list with WebKit, as Klar does (TrackerBlocker), so a list WebKit can't use isn't shipped:
// one rule it rejects and the whole list fails, leaving nothing blocked. update_tracker_list.py runs it on the new
// list before it replaces the old one.
//
// Usage: xcrun swift scripts/check_tracker_list.swift <trackers.json.deflate>

import Foundation
import WebKit

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("klar-tracker-check-\(UUID().uuidString)")

func finish(_ message: String, status: Int32) -> Never {
    try? FileManager.default.removeItem(at: folder)
    print(message)
    exit(status)
}

guard let data = try? Data(contentsOf: source),
      let json = try? (data as NSData).decompressed(using: .zlib) as Data else {
    finish("Can't read \(source.path) as raw DEFLATE", status: 1)
}
guard let store = WKContentRuleListStore(url: folder) else {
    finish("Can't make a content rule list store", status: 1)
}

let started = Date()
do {
    _ = try await store.compileContentRuleList(forIdentifier: "check", encodedContentRuleList: String(decoding: json, as: UTF8.self))
    finish(String(format: "WebKit compiled it in %.1f s", -started.timeIntervalSinceNow), status: 0)
} catch {
    finish("WebKit can't compile it: \(error)", status: 1)
}
