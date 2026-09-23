import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI

/// The secret every request to the agent carries: how it is made, kept,
/// offered and compared. `Plans/Multi-user Support.md`.
@Suite("The service secret")
struct ServiceSecretTests {

    private final class Suite {
        let name = scratchSuiteName("secret")
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        /// A fresh `Preferences` each time, as a relaunched agent would make.
        var preferences: Preferences { Preferences(suiteName: name) }

        deinit { discardScratchSuite(name) }
    }

    // MARK: - Making one

    @Test("A made secret is 64 lowercase hex digits, and no two are alike")
    func madeSecretsAreWellFormedAndDistinct() throws {
        let first = try #require(ServiceSecret.make())
        let second = try #require(ServiceSecret.make())
        #expect(first.count == 64)
        #expect(ServiceSecret.isWellFormed(first))
        #expect(first != second)
    }

    @Test("Only what make() could produce counts as a secret")
    func wellFormedIsExact() {
        let good = String(repeating: "0123456789abcdef", count: 4)
        #expect(ServiceSecret.isWellFormed(good))
        #expect(!ServiceSecret.isWellFormed(""))
        #expect(!ServiceSecret.isWellFormed("x"))
        #expect(!ServiceSecret.isWellFormed(String(good.dropLast())))
        #expect(!ServiceSecret.isWellFormed(good + "0"))
        #expect(!ServiceSecret.isWellFormed(good.uppercased()))
        #expect(!ServiceSecret.isWellFormed(String(good.dropLast()) + "g"))
    }

    // MARK: - Keeping one

    @Test("One is made when none is kept, and kept from then on")
    func madeWhenNoneIsKept() throws {
        let suite = Suite()
        #expect(suite.preferences.serviceSecret == nil)

        let made = try #require(suite.preferences.establishServiceSecret())
        #expect(suite.preferences.serviceSecret == made)
    }

    @Test("A kept secret survives a relaunch")
    func survivesARelaunch() throws {
        let suite = Suite()
        let first = try #require(suite.preferences.establishServiceSecret())
        // A second `Preferences` over the same domain is what the next launch
        // reads through. A secret made afresh would send every client back to
        // re-read it after every app launch.
        let second = suite.preferences.establishServiceSecret { Issue.record("made again"); return nil }
        #expect(second == first)
    }

    @Test("A malformed secret is replaced, not trusted")
    func malformedIsReplaced() throws {
        let suite = Suite()
        suite.defaults.set("hunter2", forKey: Preferences.Key.serviceSecret.rawValue)
        #expect(suite.preferences.serviceSecret == nil)

        let replacement = try #require(suite.preferences.establishServiceSecret())
        #expect(replacement != "hunter2")
        #expect(ServiceSecret.isWellFormed(replacement))
        #expect(suite.preferences.serviceSecret == replacement)
    }

    @Test("When none can be made, there is none — not an empty one")
    func noneWhenNoneCanBeMade() {
        let suite = Suite()
        #expect(suite.preferences.establishServiceSecret { nil } == nil)
        #expect(suite.defaults.object(forKey: Preferences.Key.serviceSecret.rawValue) == nil)
    }

    @Test("The secret is not among what `all()` reports")
    func notListed() throws {
        let suite = Suite()
        let secret = try #require(suite.preferences.establishServiceSecret())
        #expect(!Preferences.allKeys.contains(.serviceSecret))
        #expect(!suite.preferences.all().values.contains(secret))
    }

    // MARK: - Offering one

    @Test("A Bearer header offers its credential, whatever the scheme's case")
    func bearerIsRead() {
        #expect(ServiceSecret.offered(inAuthorization: "Bearer abc") == "abc")
        #expect(ServiceSecret.offered(inAuthorization: "bearer abc") == "abc")
        #expect(ServiceSecret.offered(inAuthorization: "  BEARER   abc  ") == "abc")
        #expect(ServiceSecret.authorization("abc") == "Bearer abc")
    }

    @Test("Anything else offers nothing")
    func otherHeadersOfferNothing() {
        #expect(ServiceSecret.offered(inAuthorization: nil) == nil)
        #expect(ServiceSecret.offered(inAuthorization: "") == nil)
        #expect(ServiceSecret.offered(inAuthorization: "Bearer") == nil)
        #expect(ServiceSecret.offered(inAuthorization: "Bearer   ") == nil)
        #expect(ServiceSecret.offered(inAuthorization: "Basic abc") == nil)
        #expect(ServiceSecret.offered(inAuthorization: "abc") == nil)
    }

    // MARK: - Comparing

    @Test("Only the same string matches")
    func matching() {
        let secret = String(repeating: "ab", count: 32)
        #expect(ServiceSecret.matches(secret, secret))
        #expect(!ServiceSecret.matches(String(secret.dropLast()) + "c", secret))
        #expect(!ServiceSecret.matches("", secret))
        #expect(!ServiceSecret.matches(secret, ""))
        #expect(ServiceSecret.matches("", ""))
    }

    @Test("A right secret of a different length is refused")
    func lengthCounts() {
        let secret = String(repeating: "ab", count: 32)
        #expect(!ServiceSecret.matches(String(secret.dropLast()), secret))
        #expect(!ServiceSecret.matches(secret + "a", secret))
        // A length difference of exactly 256 would vanish in the low byte of
        // an XOR; it has to count all the same.
        #expect(!ServiceSecret.matches(secret + String(repeating: "\0", count: 256), secret))
    }
}
