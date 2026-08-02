import Foundation

func ingestPodcast(
    _ request: ItemInputRequest,
    context: ItemInputContext
) async throws -> ItemDraft {
    let url = try requestURL(request)
    var episode = PodcastEpisode(
        title: request.hints.title,
        description: request.hints.content,
        guid: nil,
        link: url,
        mediaURL: request.hints.mediaURL,
        transcriptURL: request.hints.transcriptURL,
        transcriptType: request.hints.transcriptType,
        transcriptLanguage: request.hints.transcriptLanguage
    )
    var resolvedEpisode = episode.title != nil || episode.description != nil ||
        episode.mediaURL != nil || episode.transcriptURL != nil
    var showTitle: String?
    if episode.mediaURL == nil && episode.transcriptURL == nil {
        let response = try await context.http.get(url)
        if let feed = parseNativePodcastFeed(response.data, baseURL: response.finalURL) {
            showTitle = feed.title
            episode = feed.episodes.first ?? episode
            resolvedEpisode = !feed.episodes.isEmpty
        } else {
            let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
            let feedURLs = try await podcastFeedURLs(
                html: response.text,
                pageURL: response.finalURL,
                http: context.http
            )
            for feedURL in feedURLs {
                guard
                    let feedResponse = try? await context.http.get(feedURL),
                    let feed = parseNativePodcastFeed(feedResponse.data, baseURL: feedResponse.finalURL)
                else { continue }
                let match = feed.episodes.max { left, right in
                    podcastEpisodeScore(left, url: response.finalURL, title: metadata.title) <
                        podcastEpisodeScore(right, url: response.finalURL, title: metadata.title)
                }
                if let match, podcastEpisodeScore(match, url: response.finalURL, title: metadata.title) > 0 {
                    showTitle = feed.title
                    episode = match
                    resolvedEpisode = true
                    break
                }
            }
        }
    }
    guard resolvedEpisode else { throw NativeInputError.unreadableContent }
    var transcript: InputTranscript?
    var transcriptError: String?
    if let transcriptURL = episode.transcriptURL {
        do {
            let response = try await context.http.get(
                transcriptURL,
                headers: ["Accept": episode.transcriptType ?? "text/plain"],
                maximumBytes: 20_000_000
            )
            let text = parsePodcastTranscript(response.text, type: episode.transcriptType)
            guard !text.isEmpty else { throw NativeInputError.unreadableContent }
            transcript = InputTranscript(text: text, language: episode.transcriptLanguage)
        } catch {
            transcriptError = error.localizedDescription
        }
    }
    if transcript == nil, let mediaURL = episode.mediaURL, let transcribe = context.transcribe {
        do {
            transcript = try await transcribe(mediaURL)
            transcriptError = nil
        } catch {
            transcriptError = error.localizedDescription
        }
    }
    let content = transcript.map { "Transcript:\n\($0.text)" } ?? [
        "Transcript unavailable for this podcast episode.",
        episode.description.map { "\nDescription:\n\($0)" }
    ].compactMap { $0 }.joined(separator: "\n")
    return ItemDraft(
        inputID: .podcast,
        title: episode.title ?? showTitle ?? "Podcast episode",
        content: content,
        sourceURL: url,
        canonicalURL: episode.link ?? url,
        mediaURL: episode.mediaURL,
        faviconURL: URL(string: "/favicon.ico", relativeTo: episode.link ?? url)?.absoluteURL,
        transcriptAvailable: transcript != nil,
        transcriptLanguage: transcript?.language,
        transcriptError: transcriptError
    )
}
