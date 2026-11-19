// Random bytes and tokens, from the system's cryptographic generator. SecRandomCopyBytes reports a failure only by
// its status, and ignoring it would hand out the zeros the buffer started as: a token anyone could guess. A failure
// stops the process instead, as Swift's own SystemRandomNumberGenerator does. Every token Agneta issues (apps',
// diagnostics', the tool broker's) comes from here.
import Foundation
import Security

public enum SecureRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        bytes(count) { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
    }

    /// 32 random bytes as URL-safe base64 (`-` and `_` for `+` and `/`, padding kept).
    public static func token() -> String {
        Data(bytes(32)).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    /// The generator is a parameter so tests can make it fail.
    static func bytes(_ count: Int, from generate: (UnsafeMutableRawBufferPointer) -> OSStatus) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return bytes }
        let status = bytes.withUnsafeMutableBytes(generate)
        precondition(status == errSecSuccess, "The system's random generator failed (\(status))")
        return bytes
    }
}
