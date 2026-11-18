// CI runs the real-engine suites, never skips them: with AGNETA_REQUIRE_ENGINES set, a missing engine or
// agneta-shell fails the run instead of quietly skipping those suites.
import Foundation
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["AGNETA_REQUIRE_ENGINES"] != nil))
func theRealEnginesArePresentWhenRequired() {
    #expect(GooseHarness.available, "Goose is missing: run scripts/fetch-engines --engine all")
    #expect(GooseHarness.openCodeAvailable, "OpenCode is missing: run scripts/fetch-engines --engine all")
    #expect(BuiltTools.shellBuilt, "agneta-shell isn't built: run swift build")
}
