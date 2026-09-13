import Foundation

/// The durable intent to process a saved item. Travels with the document in iCloud;
/// execution and local worker jobs belong to the Mac.
public struct CaptureRequest: Codable, Hashable, Sendable {
    public enum Payload: Codable, Hashable, Sendable {
        case url(String)
        case text(String)
        case pdf(String)
    }

    public enum State: String, Codable, Sendable {
        case queued, extracting, summarizing, failed, ready
    }

    public let payload: Payload
    public var state: State = .queued
    public var hasExtractedSource = false
    public var error: String?

    public init(payload: Payload) { self.payload = payload }

    public var status: String {
        switch state {
        case .queued: "Waiting for Mac"
        case .extracting: "Extracting on Mac"
        case .summarizing: "Preparing summaries on Mac"
        case .failed: "Needs attention"
        case .ready: "Ready"
        }
    }
}
