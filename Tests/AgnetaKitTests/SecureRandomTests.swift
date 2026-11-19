import Foundation
import Security
import Testing

@testable import AgnetaKit

@Suite struct SecureRandomTests {
    /// A generator that fails stops the process: no token is ever made of the zeros the buffer started as. (Ignoring
    /// the status, as the code once did, returns those zeros and the process carries on, which fails this test.)
    @Test func aFailingGeneratorStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            _ = SecureRandom.bytes(32) { _ in errSecInternalError }
        }
    }

    /// The bytes are as many as asked and differ each time: 32 equal bytes twice would mean the generator wasn't used.
    @Test func givesFreshBytesOfTheSizeAsked() {
        let first = SecureRandom.bytes(32), second = SecureRandom.bytes(32)
        #expect(first.count == 32 && second.count == 32)
        #expect(first != second)
        #expect(first != [UInt8](repeating: 0, count: 32))
        #expect(SecureRandom.bytes(0).isEmpty)
    }

    /// Apps' and the tool broker's tokens come from it: URL-safe, 32 bytes' worth, never the same twice.
    @Test(arguments: [Router.newToken, EngineSupervisor.newToken])
    func tokensAreFreshAndURLSafe(_ newToken: @Sendable () -> String) {
        let tokens = (0..<8).map { _ in newToken() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(!token.contains("/") && !token.contains("+"))
            let base64 = token.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
            #expect(Data(base64Encoded: base64)?.count == 32)
        }
    }
}
