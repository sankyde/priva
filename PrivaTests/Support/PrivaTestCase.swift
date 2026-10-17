import UIKit
import XCTest
@testable import Priva

/// One Priva "phone" in a test: an engine and the folder its store lives in.
@MainActor struct TestNode {
    let engine: PrivaEngine
    let dir: URL
    var name: String { engine.me }
}

/// Helpers for tests that run without Priva's servers: waiting, photos, memory, metrics.
nonisolated class PrivaTestCase: XCTestCase {
    typealias Node = TestNode

    static func metric(_ name: String, _ value: Double, _ unit: String) {
        print(String(format: "METRIC %@ = %.2f %@", name, value, unit))
    }

    @MainActor func waitUntil(_ what: String, timeout: TimeInterval = 30, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                XCTFail("Timed out waiting for: \(what)")
                throw XCTSkip("timeout: \(what)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Asserts `cond` stays false for `seconds` (for "this must NOT happen" checks).
    @MainActor func assertNever(_ what: String, for seconds: TimeInterval = 3, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { XCTFail("Should not happen: \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor func thread(_ n: Node, _ key: String) -> [Message] { n.engine.loadThread(key) }

    /// A small real JPEG, prepared the way the photo picker path does.
    nonisolated static func photo(width: Int = 900, height: Int = 600) throws -> MediaPrep.Prepared {
        let r = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let img = r.image { ctx in
            UIColor.systemIndigo.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: width / 3, height: height / 2))
        }
        return try MediaPrep.image(from: try XCTUnwrap(img.jpegData(compressionQuality: 0.8)))
    }

    /// Heap bytes actually in use (all malloc zones): steadier than resident pages for spotting leaks.
    nonisolated static func heapMB() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }

    /// Resident memory of this process (for soak tests).
    nonisolated static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
