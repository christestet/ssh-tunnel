import Foundation
import XCTest
@testable import SSHTunnelKit

// MARK: - Test doubles

final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    enum Outcome {
        case success(GitHubRelease)
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcome: Outcome
    private var _callCount = 0

    init(_ outcome: Outcome) { self.outcome = outcome }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func fetchLatestRelease() async throws -> GitHubRelease {
        lock.lock()
        _callCount += 1
        let current = outcome
        lock.unlock()
        switch current {
        case let .success(release): return release
        case let .failure(error): throw error
        }
    }
}

final class SpyUpdateNotifier: UpdateNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _notifications: [(version: String, url: URL)] = []

    var notifications: [(version: String, url: URL)] {
        lock.lock(); defer { lock.unlock() }
        return _notifications
    }

    func sendUpdateAvailableNotification(version: String, releaseURL: URL) {
        lock.lock()
        _notifications.append((version, releaseURL))
        lock.unlock()
    }
}

/// A clock whose `now` can be advanced between checks.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date += interval
        lock.unlock()
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func makeStore() -> UpdateSettingsStore {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests-\(UUID().uuidString)")!
        return UpdateSettingsStore(defaults: defaults)
    }

    private func release(
        tag: String,
        prerelease: Bool = false,
        draft: Bool = false
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: tag,
            htmlURL: "https://github.com/christestet/ssh-tunnel/releases/tag/\(tag)",
            body: "notes",
            prerelease: prerelease,
            draft: draft
        )
    }

    // MARK: - Version comparison

    @MainActor
    func testNewerReleaseSetsAvailableUpdate() async {
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertEqual(checker.availableUpdate?.version, "v2.3.0")
        XCTAssertEqual(
            checker.availableUpdate?.releaseURL.absoluteString,
            "https://github.com/christestet/ssh-tunnel/releases/tag/v2.3.0"
        )
        XCTAssertNil(checker.lastErrorMessage)
    }

    @MainActor
    func testSameVersionClearsUpdate() async {
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.2.4")))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testOlderVersionClearsUpdate() async {
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.1.0")))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testPrereleaseIsIgnored() async {
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v3.0.0", prerelease: true)))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testDraftIsIgnored() async {
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v3.0.0", draft: true)))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testFetchErrorSetsMessageAndDoesNotCrash() async {
        let fetcher = FakeReleaseFetcher(.failure(UpdateCheckError.httpStatus(503)))
        let checker = UpdateChecker(fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4")

        await checker.checkForUpdates()

        XCTAssertNil(checker.availableUpdate)
        XCTAssertNotNil(checker.lastErrorMessage)
    }

    // MARK: - 24h gate

    @MainActor
    func testAutomaticCheckSkippedWhenCheckedRecently() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        store.lastCheckDate = base.addingTimeInterval(-3600) // 1h ago
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 0)
    }

    @MainActor
    func testAutomaticCheckRunsWhenStale() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        store.lastCheckDate = base.addingTimeInterval(-25 * 3600) // 25h ago
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(store.lastCheckDate, base)
        XCTAssertEqual(checker.availableUpdate?.version, "v2.3.0")
    }

    @MainActor
    func testAutomaticCheckRunsWhenNeverChecked() async {
        let store = makeStore()
        XCTAssertNil(store.lastCheckDate)
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(fetcher: fetcher, settings: store, currentVersion: "2.2.4")

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 1)
    }

    @MainActor
    func testAutomaticCheckSkippedWhenDisabled() async {
        let store = makeStore()
        store.automaticChecksEnabled = false
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(fetcher: fetcher, settings: store, currentVersion: "2.2.4")

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 0)
    }

    @MainActor
    func testManualCheckAlwaysRunsRegardlessOfGate() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        store.lastCheckDate = base // just checked
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.checkForUpdates()

        XCTAssertEqual(fetcher.callCount, 1)
    }

    // MARK: - Notifications

    @MainActor
    func testBackgroundDiscoveryNotifies() async {
        let notifier = SpyUpdateNotifier()
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4", notifier: notifier
        )

        await checker.automaticCheckIfDue()

        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(notifier.notifications.first?.version, "v2.3.0")
    }

    @MainActor
    func testManualCheckDoesNotNotify() async {
        let notifier = SpyUpdateNotifier()
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: makeStore(), currentVersion: "2.2.4", notifier: notifier
        )

        await checker.checkForUpdates()

        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    @MainActor
    func testNotifiesOnlyOncePerVersion() async {
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1_000_000))
        let notifier = SpyUpdateNotifier()
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher,
            settings: makeStore(),
            currentVersion: "2.2.4",
            notifier: notifier,
            now: { clock.now }
        )

        await checker.automaticCheckIfDue()
        clock.advance(by: 25 * 3600)
        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 2)
        XCTAssertEqual(notifier.notifications.count, 1)
    }

    // MARK: - JSON decoding

    func testDecodesRealGitHubPayload() throws {
        let json = """
        {
          "tag_name": "v2.3.0",
          "name": "v2.3.0",
          "html_url": "https://github.com/christestet/ssh-tunnel/releases/tag/v2.3.0",
          "body": "## What's Changed\\n* In-app update check",
          "prerelease": false,
          "draft": false,
          "id": 12345,
          "assets": []
        }
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))

        XCTAssertEqual(release.tagName, "v2.3.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/christestet/ssh-tunnel/releases/tag/v2.3.0")
        XCTAssertFalse(release.prerelease)
        XCTAssertFalse(release.draft)
    }
}
