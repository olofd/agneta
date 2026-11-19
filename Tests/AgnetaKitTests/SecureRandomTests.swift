import Foundation
import Testing

@testable import AgnetaKit

@Suite struct SecureRandomTests {
    /// The bytes are as many as asked and differ each time: 32 equal bytes twice would mean the generator wasn't used.
    @Test func givesFreshBytesOfTheSizeAsked() {
        let first = SecureRandom.bytes(32), second = SecureRandom.bytes(32)
        #expect(first.count == 32 && second.count == 32)
        #expect(first != second)
        #expect(first != [UInt8](repeating: 0, count: 32))
        #expect(SecureRandom.bytes(0).isEmpty)
    }

    /// App tokens come from it: URL-safe, 32 bytes' worth, never the same twice.
    @Test func appTokensAreFreshAndURLSafe() {
        let tokens = (0..<8).map { _ in Router.newToken() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(!token.contains("/") && !token.contains("+"))
            let base64 = token.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
            #expect(Data(base64Encoded: base64)?.count == 32)
        }
    }
}
