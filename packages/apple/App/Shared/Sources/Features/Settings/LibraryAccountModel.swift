import AuthenticationServices
import BrieflyCore
import Observation

@MainActor
@Observable
final class LibraryAccountModel {
    let session: LibrarySession
    var account: BrieflyAccountStatus
    var isSigningInForReview = false
    var isCheckingAccount = false
    var isDeletingAccount = false

    init(session: LibrarySession) {
        self.session = session
        account = BrieflyAccountCache.load() ?? .signedOut
    }

    func refreshAccount(reportErrors: Bool = false) async {
        guard !isCheckingAccount else { return }
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            updateAccount(try await session.backend.accountStatus())
        } catch {
            if reportErrors { session.errorMessage = error.localizedDescription }
        }
    }

    func signOut() async {
        do {
            try await session.backend.signOut()
            updateAccount(.signedOut)
            session.status = "Signed out of Briefly"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func deleteAccount() async {
        guard account.authenticated, !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await session.backend.deleteAccount()
            updateAccount(.signedOut)
            session.status = "Briefly account deleted"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func signInWithApple(
        _ result: Result<ASAuthorization, Error>,
        nonce: String
    ) async {
        do {
            guard
                case .success(let authorization) = result,
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityToken = credential.identityToken,
                let authorizationCode = credential.authorizationCode,
                !nonce.isEmpty
            else {
                if case .failure(let error) = result { throw error }
                throw BrieflyBackendError.message("Apple sign-in did not return a credential.")
            }
            updateAccount(try await session.backend.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce
            ))
            session.status = "Signed in with Apple"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func signInForAppReview(username: String, password: String) async {
        guard !isSigningInForReview else { return }
        isSigningInForReview = true
        defer { isSigningInForReview = false }
        do {
            updateAccount(try await session.backend.signInForAppReview(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            ))
            session.status = "Signed in for App Review"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }


    private func updateAccount(_ value: BrieflyAccountStatus) {
        account = value
        BrieflyAccountCache.save(value)
    }
}

private enum BrieflyAccountCache {
    private struct Entry: Codable {
        let account: BrieflyAccountStatus
        let checkedAt: Date
    }

    private static let key = "BrieflyVerifiedAccount"
    private static let maximumAge: TimeInterval = 24 * 60 * 60

    static func load(now: Date = .now) -> BrieflyAccountStatus? {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let entry = try? JSONDecoder().decode(Entry.self, from: data),
            entry.account.authenticated,
            now.timeIntervalSince(entry.checkedAt) <= maximumAge
        else {
            return nil
        }
        return entry.account
    }

    static func save(_ account: BrieflyAccountStatus, now: Date = .now) {
        guard account.authenticated else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let entry = Entry(account: account, checkedAt: now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
