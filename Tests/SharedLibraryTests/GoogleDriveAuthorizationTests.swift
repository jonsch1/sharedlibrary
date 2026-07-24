import Foundation
import XCTest
@testable import SharedLibrary

final class GoogleDriveAuthorizationTests: XCTestCase {
    func testLoopbackReceiverAcceptsOAuthCallback() async throws {
        let receiver = try await OAuthLoopbackReceiver.start()
        var components = URLComponents(
            url: receiver.redirectURI,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "code", value: "test-code"),
            URLQueryItem(name: "state", value: "test-state")
        ]

        let callbackTask = Task {
            try await receiver.waitForCallback()
        }
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        let callback = try await callbackTask.value
        let callbackItems = URLComponents(
            url: callback,
            resolvingAgainstBaseURL: false
        )?.queryItems

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            callbackItems?.first(where: { $0.name == "code" })?.value,
            "test-code"
        )
        XCTAssertEqual(
            callbackItems?.first(where: { $0.name == "state" })?.value,
            "test-state"
        )
    }

    func testOAuthErrorPayloadIncludesGoogleDescription() {
        let data = Data(
            """
            {
              "error": "invalid_grant",
              "error_description": "Authorization code could not be exchanged."
            }
            """.utf8
        )

        XCTAssertEqual(
            googleErrorMessage(data),
            "Authorization code could not be exchanged. (invalid_grant)"
        )
    }

    func testAuthorizationCodeExchangeIncludesClientSecret() {
        let data = googleAuthorizationCodeFormData(
            code: "authorization-code",
            clientID: "desktop-client-id",
            clientSecret: "desktop secret/+",
            verifier: "pkce-verifier",
            redirectURI: URL(string: "http://127.0.0.1:49152")!
        )
        let values = formValues(data)

        XCTAssertEqual(values["client_secret"], "desktop secret/+")
        XCTAssertEqual(values["grant_type"], "authorization_code")
        XCTAssertEqual(values["redirect_uri"], "http://127.0.0.1:49152")
    }

    func testRefreshExchangeIncludesStoredClientSecret() {
        let token = GoogleDriveAccessToken(
            clientID: "desktop-client-id",
            clientSecret: "desktop-secret",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: .distantFuture
        )

        XCTAssertEqual(
            formValues(googleRefreshTokenFormData(token))["client_secret"],
            "desktop-secret"
        )
    }

    private func formValues(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
    }
}
