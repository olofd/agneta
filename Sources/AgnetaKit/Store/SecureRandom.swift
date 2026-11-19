// Random bytes for tokens and salts, from the system's cryptographic generator. SecRandomCopyBytes reports a failure
// only by its status, and ignoring it would hand out the zeros the buffer started as: a token anyone could guess. A
// failure stops the process instead, as Swift's own SystemRandomNumberGenerator does.
import Security

public enum SecureRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes
    }
}
