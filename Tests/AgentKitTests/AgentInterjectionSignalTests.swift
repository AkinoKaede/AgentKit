import Testing

@testable import AgentKit

@Suite
struct AgentInterjectionSignalTests {
    @Test @MainActor
    func preCancelledWaitDoesNotRegisterAfterItsCancellationHandler() async throws {
        let signal = AgentInterjectionSignal()
        var returned = false
        let waiter = Task { @MainActor in
            await signal.wait()
            returned = true
        }

        // This task cannot start on the main actor until this test yields, so
        // cancellation is guaranteed to precede waiter registration.
        waiter.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let returnedBeforeArm = returned

        // Always release the old broken implementation so a failing regression
        // reports promptly instead of leaving the suite suspended.
        signal.arm()
        await waiter.value
        #expect(returnedBeforeArm)
    }
}
