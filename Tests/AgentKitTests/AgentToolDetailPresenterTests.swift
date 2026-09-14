import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentToolDetailPresenterTests {
    @Test
    func toolCanRegisterAnArgumentProjectionBesideItsResultProjection() throws {
        let presenter = AgentToolDetailPresenter(
            id: "test.registered",
            present: { _ in [.message("result", .success)] },
            presentArguments: { input in
                [
                    .field(
                        .init(
                            label: "Destination",
                            value: input.arguments["target"]?.stringValue ?? ""
                        ))
                ]
            }
        )

        let projected = try #require(
            presenter.presentArguments(
                .init(
                    arguments: ["target": .string("production")],
                    locale: Locale(identifier: "en")
                )))
        #expect(projected == [.field(.init(label: "Destination", value: "production"))])
    }

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
