import AgentKit
import Testing

@Suite
struct AgentByteCountFormatterTests {
    @Test func zeroHasNoUnitAndFileSizesUseDecimalThresholds() {
        #expect(AgentByteCountFormatter.string(fromByteCount: 0) == "0")
        #expect(AgentByteCountFormatter.string(fromByteCount: 1).contains("byte"))
        #expect(AgentByteCountFormatter.string(fromByteCount: 999).contains("999"))
        #expect(AgentByteCountFormatter.string(fromByteCount: 1_000).contains("KB"))
        #expect(AgentByteCountFormatter.string(fromByteCount: 1_000_000).contains("MB"))
    }

    @Test func negativeCountsAreUnavailable() {
        #expect(AgentByteCountFormatter.string(fromByteCount: -1) == "—")
    }

    @Test func toolDetailsUseTheSharedFormatter() {
        #expect(AgentToolDetailFormatting.byteCount(0) == "0")
    }
}
