import Foundation
import Security

/// What proves a request came from this user, and what the agent checks for.
///
/// **Loopback keeps other machines out, not other accounts on this one.** Every
/// account on a Mac shares loopback, and the agent's port is worked out from
/// the user name, so until this existed anyone logged in could compute another
/// user's port and be handed their pictures. Each agent now keeps a secret in
/// its own preference domain — which only its user can read — and refuses any
/// request that does not carry it. `Plans/Multi-user Support.md`.
///
/// **Kept, not remade each launch.** The app restarts the agent on every launch
/// of its own; a new secret each time would send every running client back to
/// re-read it. It names the user, not the process, so unlike the port it is
/// never withdrawn.
public enum ServiceSecret {

    /// Thirty-two random bytes, which is 64 hex digits.
    public static let byteCount = 32

    /// The header a client sends and the agent reads.
    public static let headerField = "Authorization"

    /// A new secret, or nil when the system would not produce random bytes —
    /// which the agent treats as a reason not to start, since serving
    /// unguarded is the one outcome this exists to prevent.
    public static func make() -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            return nil
        }
        return hex(bytes)
    }

    /// Whether a stored value is one `make()` could have produced.
    ///
    /// **Anything else is replaced, not trusted.** `defaults write` accepts
    /// anything, and a secret of `"x"` would be a secret anybody could guess.
    public static func isWellFormed(_ candidate: String) -> Bool {
        candidate.utf8.count == byteCount * 2
            && candidate.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `Bearer <secret>`, the header's value.
    public static func authorization(_ secret: String) -> String {
        "Bearer \(secret)"
    }

    /// The secret a header offers, or nil when it offers none.
    ///
    /// The scheme is compared without regard to case, as HTTP says it must be;
    /// the credential is taken as it stands.
    public static func offered(inAuthorization header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let scheme = "bearer "
        guard trimmed.count > scheme.count, trimmed.lowercased().hasPrefix(scheme) else {
            return nil
        }
        let credential = trimmed.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return credential.isEmpty ? nil : credential
    }

    /// Whether two strings are the same, taking as long to say no as to say yes.
    ///
    /// **Every byte of the longer is looked at, and a difference in length
    /// counts as a difference.** An answer's timing then says nothing about how
    /// much of a guess was right — and a local account timing answers on
    /// loopback is exactly who the secret is for.
    public static func matches(_ offered: String, _ secret: String) -> Bool {
        let left = Array(offered.utf8)
        let right = Array(secret.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        difference |= left.count == right.count ? 0 : 1
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
