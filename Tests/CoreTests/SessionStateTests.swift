import XCTest
@testable import ClaudeUsageBarCore

final class SessionStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ count: Int) -> Date { now.addingTimeInterval(Double(count) * 86_400) }

    func test_healthy_whenExpiryIsFarAway() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_expiringSoon_atThreeDaysOrLess() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(3), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .expiringSoon(daysRemaining: 3))
    }

    func test_stillHealthy_atFourDays() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(4), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_needsSignIn_whenExpired() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(-1), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .needsSignIn)
    }

    func test_needsSignIn_afterTwoAuthFailures() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 2,
                                           lastFetchFailedNonAuth: false, now: now),
            .needsSignIn)
    }

    func test_singleAuthFailure_doesNotDemandSignIn() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 1,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_temporarilyUnavailable_onNonAuthFailure() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: true, now: now),
            .temporarilyUnavailable)
    }

    func test_unknownExpiry_isHealthy() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: nil, consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_expiringSoon_outranksNetworkFailure() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(2), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: true, now: now),
            .expiringSoon(daysRemaining: 2))
    }

    func test_renewal_attemptedInsideSevenDayWindow() {
        XCTAssertTrue(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: nil, now: now))
    }

    func test_renewal_notAttemptedOutsideWindow() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(20), lastRenewalAttempt: nil, now: now))
    }

    func test_renewal_rateLimitedToOncePerDay() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: now.addingTimeInterval(-25 * 3600), now: now))
    }

    func test_renewal_notAttemptedWhenAlreadyExpiredOrUnknown() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(-1), lastRenewalAttempt: nil, now: now))
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: nil, lastRenewalAttempt: nil, now: now))
    }
}