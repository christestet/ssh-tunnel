import Foundation
import Synchronization
import XCTest
@testable import SSHTunnelKit

// MARK: - Test doubles

final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    enum Outcome {
        case success(GitHubRelease)
        case failure(Error)
    }

    private let outcome: Outcome
    // `Mutex.withLock` is async-safe scoped locking; `NSLock.lock()/unlock()`
    // are unavailable from the `async` fetch method under Swift 6.
    private let callCountStorage = Mutex(0)

    init(_ outcome: Outcome) { self.outcome = outcome }

    var callCount: Int { callCountStorage.withLock { $0 } }

    func fetchLatestRelease() async throws -> GitHubRelease {
        callCountStorage.withLock { $0 += 1 }
        switch outcome {
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
    @MainActor
    private func makeStore() -> UpdateSettingsStore {
        let suite = "UpdateCheckerTests-\(UUID().uuidString)"
        // Clean up the leaked plist suite after the test, matching TunnelLogTests.
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UpdateSettingsStore(defaults: UserDefaults(suiteName: suite)!)
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
    func testAutomaticCheckSkippedWhenSucceededRecently() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        store.lastSuccessDate = base.addingTimeInterval(-3600) // 1h ago
        store.lastAttemptDate = base.addingTimeInterval(-3600)
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 0)
    }

    @MainActor
    func testAutomaticCheckRunsWhenSuccessWindowElapsed() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        store.lastSuccessDate = base.addingTimeInterval(-25 * 3600) // 25h ago
        store.lastAttemptDate = base.addingTimeInterval(-25 * 3600)
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.automaticCheckIfDue()

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(store.lastSuccessDate, base)
        XCTAssertEqual(store.lastAttemptDate, base)
        XCTAssertEqual(checker.availableUpdate?.version, "v2.3.0")
    }

    @MainActor
    func testAutomaticCheckRunsWhenNeverChecked() async {
        let store = makeStore()
        XCTAssertNil(store.lastSuccessDate)
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
        store.lastSuccessDate = base // just succeeded
        store.lastAttemptDate = base
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.checkForUpdates()

        XCTAssertEqual(fetcher.callCount, 1)
    }

    @MainActor
    func testFailedCheckDoesNotBlockRetryForFullDay() async {
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = makeStore()
        let fetcher = FakeReleaseFetcher(.failure(UpdateCheckError.httpStatus(503)))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { clock.now }
        )

        // First attempt fails — no success recorded, only an attempt timestamp.
        await checker.automaticCheckIfDue()
        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertNil(store.lastSuccessDate)

        // Within the retry floor (30m < 1h): must not hammer.
        clock.advance(by: 30 * 60)
        await checker.automaticCheckIfDue()
        XCTAssertEqual(fetcher.callCount, 1)

        // After the retry floor (well past 1h, still far short of 24h): retries.
        clock.advance(by: 2 * 3600)
        await checker.automaticCheckIfDue()
        XCTAssertEqual(fetcher.callCount, 2)
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

    @MainActor
    func testDoesNotReNotifySameVersionAcrossRelaunch() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // Simulate a relaunch: the store already saw this version (persisted),
        // and the success window has elapsed so a fresh check is due.
        let store = makeStore()
        store.lastNotifiedVersion = "v2.3.0"
        store.lastSuccessDate = base.addingTimeInterval(-25 * 3600)
        store.lastAttemptDate = base.addingTimeInterval(-25 * 3600)
        let notifier = SpyUpdateNotifier()
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", notifier: notifier, now: { base }
        )

        await checker.automaticCheckIfDue()

        // The banner still surfaces the update, but no duplicate notification.
        XCTAssertEqual(checker.availableUpdate?.version, "v2.3.0")
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testNotificationReleaseURLReadsValidUserInfoString() {
        let url = UserNotificationUpdateNotifier.releaseURL(from: [
            UserNotificationUpdateNotifier.releaseURLKey: "https://github.com/christestet/ssh-tunnel/releases/tag/v2.3.0"
        ])

        XCTAssertEqual(
            url?.absoluteString,
            "https://github.com/christestet/ssh-tunnel/releases/tag/v2.3.0"
        )
    }

    func testNotificationReleaseURLIgnoresInvalidUserInfo() {
        XCTAssertNil(UserNotificationUpdateNotifier.releaseURL(from: [:]))
        XCTAssertNil(UserNotificationUpdateNotifier.releaseURL(from: [
            UserNotificationUpdateNotifier.releaseURLKey: 42
        ]))
        XCTAssertNil(UserNotificationUpdateNotifier.releaseURL(from: [
            UserNotificationUpdateNotifier.releaseURLKey: ""
        ]))
        XCTAssertNil(UserNotificationUpdateNotifier.releaseURL(from: [
            UserNotificationUpdateNotifier.releaseURLKey: "release-notes"
        ]))
    }

    // MARK: - Loop scheduling

    @MainActor
    func testNextDelayWaits24hAfterSuccessAndPollsWhenDisabled() async {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = makeStore()
        let fetcher = FakeReleaseFetcher(.success(release(tag: "v2.3.0")))
        let checker = UpdateChecker(
            fetcher: fetcher, settings: store, currentVersion: "2.2.4", now: { base }
        )

        await checker.checkForUpdates() // success at `base`
        XCTAssertEqual(checker.nextAutomaticCheckDelay(), .seconds(24 * 3600))

        store.automaticChecksEnabled = false
        XCTAssertEqual(checker.nextAutomaticCheckDelay(), UpdateChecker.disabledPollInterval)
    }

    // MARK: - JSON decoding

    func testLatestReleaseURLPinsTheEndpoint() {
        let url = GitHubReleaseFetcher.latestReleaseURL(
            owner: GitHubReleaseFetcher.defaultOwner,
            repo: GitHubReleaseFetcher.defaultRepo
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://api.github.com/repos/christestet/ssh-tunnel/releases/latest"
        )
    }

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
