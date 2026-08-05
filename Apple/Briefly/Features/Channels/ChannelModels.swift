import Foundation

struct SignedInChannelItem: Decodable {
    let id: String
    let title: String
    let url: String
    let publishedAt: String?
    let content: String
}

struct SignedInChannelPage {
    let title: String
    let text: String
    let items: [SignedInChannelItem]
    let faviconData: Data?
    let faviconFileExtension: String?
}

struct RedditPage: Decodable {
    let title: String
    let post: String
    let comments: [String]
    let linkedURL: String
}
