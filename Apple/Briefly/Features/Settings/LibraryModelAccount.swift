import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

extension LibraryModel {
    func deleteTopic(_ title: String) async {
        guard let library else { return }
        do {
            let definitions = try await library.topicDefinitions()
            guard let topic = definitions.first(where: { $0.title == title }) else {
                throw BrieflyBackendError.message("That collection no longer exists.")
            }
            try await library.deleteTopicDefinition(id: topic.id)
            if selectedTopic == title { showInbox() }
            await refreshLibrary()
            status = "Collection deleted. Its notes are still in your library."
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAccount(reportErrors: Bool = false) async {
        guard !isCheckingAccount else { return }
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            account = try await backend.accountStatus()
        } catch {
            account = .signedOut
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    func signOut() async {
        do {
            try await backend.signOut()
            account = .signedOut
            status = "Signed out of Briefly"
        } catch {
            errorMessage = error.localizedDescription
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
                !nonce.isEmpty
            else {
                if case .failure(let error) = result { throw error }
                throw BrieflyBackendError.message("Apple sign-in did not return a credential.")
            }
            account = try await backend.signInWithApple(
                identityToken: identityToken,
                nonce: nonce
            )
            status = "Signed in with Apple"
            await syncStoreEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSubscription() async {
        do {
            subscriptionProduct = try await Product.products(
                for: [Self.subscriptionProductID]
            ).first
            await syncStoreEntitlements()
        } catch {
            errorMessage = error.localizedDescription
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
                account = try await backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
                status = "Briefly membership activated"
            case .success(.unverified):
                throw BrieflyBackendError.message("The App Store purchase could not be verified.")
            case .pending:
                status = "The App Store purchase is awaiting approval"
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreSubscription() async {
        guard account.authenticated, !isPurchasingSubscription else { return }
        isPurchasingSubscription = true
        defer { isPurchasingSubscription = false }
        do {
            try await AppStore.sync()
            await syncStoreEntitlements()
            status = account.entitled == true
                ? "Briefly membership restored"
                : "No active Briefly membership was found"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncStoreEntitlements() async {
        guard account.authenticated else { return }
        do {
            for await result in Transaction.currentEntitlements {
                guard
                    case .verified(let transaction) = result,
                    transaction.productID == Self.subscriptionProductID
                else { continue }
                account = try await backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
            }
            if account.entitled != true { await refreshAccount() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
