import Foundation

public nonisolated enum ProviderNetworking {
    public static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public static func authorize(
        _ request: inout URLRequest,
        provider: ModelProvider,
        secret: String,
        omittingEmptyCredential: Bool = false
    ) async throws {
        switch provider.apiFormat {
        case .chatCompletions, .responses:
            if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        case .messages:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue(secret, forHTTPHeaderField: "x-api-key")
            }
        case .generateContent:
            if provider.usesVertex {
                let token = try await GoogleServiceAccountAuth.shared.accessToken(
                    serviceAccountJSON: secret
                )
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
            }
        }
    }

    public static func data(for request: URLRequest, using session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ModelCatalogError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.transport(
                String(localized: "The endpoint did not answer with HTTP.", bundle: .module)
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelCatalogError(status: http.statusCode, body: data)
        }
        return data
    }
}
