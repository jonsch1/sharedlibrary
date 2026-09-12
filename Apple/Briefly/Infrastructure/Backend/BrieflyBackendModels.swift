import Foundation
import BrieflyCore

struct BrieflyAccountStatus: Codable, Equatable {
    let authenticated: Bool
    let reviewAccess: Bool?
    let email: String?
    let accountID: UUID?

    static let signedOut = Self(
        authenticated: false,
        reviewAccess: false,
        email: nil,
        accountID: nil
    )
}
struct BrieflyShareLinkStatus: Decodable, Equatable {
    let shared: Bool
    let token: String?
    let url: String?
    let status: String?
    let error: String?
}

struct BrieflyShareSource: Encodable {
    struct Text: Encodable {
        let variant: String
        let markdown: String
    }

    let filename: String
    let title: String
    let excerpt: String
    let topicIDs: [String]
    let topicNames: [String]
    let tags: [String]
    let sourceURL: String?
    let createdAt: String?
    let updatedAt: String?
    let texts: [Text]
}
