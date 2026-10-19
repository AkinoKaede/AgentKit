import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentToolDetailPresenterTests {
    @Test
    func presenterWithoutAnArgumentProjectionRequestsTheGenericFallback() {
        let presenter = AgentToolDetailPresenter(
            id: "test.legacy",
            present: { _ in [.message("result", .success)] }
        )

        #expect(
            presenter.presentArguments(
                .init(arguments: ["target": .string("production")], locale: .current)
            ) == nil
        )
    }
}
