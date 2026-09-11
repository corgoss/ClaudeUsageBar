import Foundation

public enum SessionState: Equatable {
    case healthy
    case expiringSoon(daysRemaining: Int)
    case needsSignIn
    case temporarilyUnavailable
}

public enum SessionStateEvaluator {

    private static let expiringSoonThresholdDays = 3
    private static let renewalWindowDays = 7
    private static let renewalCooldown: TimeInterval = 24 * 3600

    private static func fullDaysBetween(_ from: Date, _ to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
    }

    public static func evaluate(expiresAt: Date?,
                                consecutiveAuthFailures: Int,
                                lastFetchFailedNonAuth: Bool,
                                now: Date = Date()) -> SessionState {
        if consecutiveAuthFailures >= 2 { return .needsSignIn }

        if let expiresAt {
            if expiresAt <= now { return .needsSignIn }
            let remaining = fullDaysBetween(now, expiresAt)
            if remaining <= expiringSoonThresholdDays {
                return .expiringSoon(daysRemaining: max(0, remaining))
            }
        }

        if lastFetchFailedNonAuth { return .temporarilyUnavailable }
        return .healthy
    }

    public static func shouldAttemptRenewal(expiresAt: Date?,
                                            lastRenewalAttempt: Date?,
                                            now: Date = Date()) -> Bool {
        guard let expiresAt, expiresAt > now else { return false }
        guard fullDaysBetween(now, expiresAt) <= renewalWindowDays else { return false }
        if let lastRenewalAttempt, now.timeIntervalSince(lastRenewalAttempt) < renewalCooldown {
            return false
        }
        return true
    }
}