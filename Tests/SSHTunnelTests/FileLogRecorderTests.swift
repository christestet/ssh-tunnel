import XCTest
@testable import SSHTunnelKit

final class FileLogRecorderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileLogRecorderTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWritesEntriesToFile() throws {
        let url = tempDir.appendingPathComponent("tunnel.log")
        let recorder = try FileLogRecorder(fileURL: url)
        recorder.log(.info, .ssh, "hello")
        recorder.log(.error, .master, tunnel: "db", "boom")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
        XCTAssertTrue(contents.contains("boom"))
        XCTAssertTrue(contents.contains("[db]"))
    }

    func testAppendsAcrossRecorderInstances() throws {
        let url = tempDir.appendingPathComponent("tunnel.log")
        let first = try FileLogRecorder(fileURL: url)
        first.log(.notice, .lifecycle, "run-1 launch")

        // Simulates an app restart: a brand new recorder over the same file.
        let second = try FileLogRecorder(fileURL: url)
        second.log(.notice, .lifecycle, "run-2 launch")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("run-1 launch"))
        XCTAssertTrue(contents.contains("run-2 launch"))
    }

    func testRotatesWhenExceedingMaxBytes() throws {
        let url = tempDir.appendingPathComponent("tunnel.log")
        // Tiny budget so a couple of lines force a rotation.
        let recorder = try FileLogRecorder(fileURL: url, maxBytes: 200)
        for i in 0..<50 {
            recorder.log(.info, .ssh, "line number \(i) with some padding text")
        }

        let primarySize = try fileSize(url)
        XCTAssertLessThanOrEqual(primarySize, 400, "primary log should be bounded by rotation")

        let rotated = url.appendingPathExtension("1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "rotation should produce a .1 backup file"
        )
    }

    func testCreatesParentDirectory() throws {
        let nested = tempDir.appendingPathComponent("a/b/c/tunnel.log")
        let recorder = try FileLogRecorder(fileURL: nested)
        recorder.log(.info, .ssh, "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }
}
