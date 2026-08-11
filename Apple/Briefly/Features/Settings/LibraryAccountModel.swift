import AuthenticationServices
import BrieflyCore
import Observation
import StoreKit

@MainActor
@Observable
final class LibraryAccountModel {
    static let subscriptionProductID = "fyi.readbriefly.plus.monthly"

    let session: LibrarySession
    var account = BrieflyAccountStatus.signedOut
    var subscriptionProduct: Product?
    var isLoadingSubscription = false
    var subscriptionLoadMessage: String?
    var isPurchasingSubscription = false
    var isSigningInForReview = false
    var isCheckingAccount = false
    var isDeletingAccount = false

    init(session: LibrarySession) {
        self.session = session
    }

    func refreshAccount(reportErrors: Bool = false) async {
        guard !isCheckingAccount else { return }
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            account = try await session.backend.accountStatus()
        } catch {
            account = .signedOut
            if reportErrors { session.errorMessage = error.localizedDescription }
        }
    }

    func signOut() async {
        do {
            try await session.backend.signOut()
            account = .signedOut
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
            account = .signedOut
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
            account = try await session.backend.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce
            )
            session.status = "Signed in with Apple"
            await syncStoreEntitlements()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func loadSubscription() async {
        guard !isLoadingSubscription else { return }
        isLoadingSubscription = true
        subscriptionLoadMessage = nil
        defer { isLoadingSubscription = false }
        do {
            let product = try await Product.products(
                for: [Self.subscriptionProductID]
            ).first
            subscriptionProduct = product
            guard product != nil else {
                subscriptionLoadMessage = "The App Store price is unavailable."
                return
            }
            await syncStoreEntitlements()
        } catch {
            subscriptionLoadMessage = "The App Store price could not be loaded."
            session.errorMessage = error.localizedDescription
        }
    }

    func signInForAppReview(username: String, password: String) async {
        guard !isSigningInForReview else { return }
        isSigningInForReview = true
        defer { isSigningInForReview = false }
        do {
            account = try await session.backend.signInForAppReview(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            session.status = "Signed in for App Review"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func purchaseSubscription() async {
        guard
            let product = subscriptionProduct,
            let accountID = account.accountID,
            !isPurchasingSubscription
        else { return }
        isPurchasingSubscription = true
        defer { isPurchasingSubscription = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(accountID)]) {
            case .success(.verified(let transaction)):
                account = try await session.backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
                session.status = "Briefly membership activated"
            case .success(.unverified):
                throw BrieflyBackendError.message("The App Store purchase could not be verified.")
            case .pending:
                session.status = "The App Store purchase is awaiting approval"
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func restoreSubscription() async {
        guard account.authenticated, !isPurchasingSubscription else { return }
        isPurchasingSubscription = true
        defer { isPurchasingSubscription = false }
        do {
            try await AppStore.sync()
            await syncStoreEntitlements()
            session.status = account.entitled == true
                ? "Briefly membership restored"
                : "No active Briefly membership was found"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func syncStoreEntitlements() async {
        guard account.authenticated else { return }
        do {
            for await result in Transaction.currentEntitlements {
                guard
                    case .verified(let transaction) = result,
                    transaction.productID == Self.subscriptionProductID
                else { continue }
                account = try await session.backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
            }
            if account.entitled != true { await refreshAccount() }
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}
