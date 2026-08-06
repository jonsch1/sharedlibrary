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
    var pageMetadata: InputHTMLMetadata?
    if episode.mediaURL == nil && episode.transcriptURL == nil {
        let response = try await context.http.get(url)
        if let feed = parseNativePodcastFeed(response.data, baseURL: response.finalURL) {
            showTitle = feed.title
            episode = feed.episodes.first ?? episode
            resolvedEpisode = !feed.episodes.isEmpty
        } else {
            let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
            pageMetadata = metadata
            let matchingURL = metadata.canonicalURL ?? response.finalURL
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
                    podcastEpisodeScore(left, url: matchingURL, title: metadata.title) <
                        podcastEpisodeScore(right, url: matchingURL, title: metadata.title)
                }
                if let match, podcastEpisodeScore(match, url: matchingURL, title: metadata.title) > 0 {
                    showTitle = feed.title
                    episode = match
                    episode.description = episode.description ?? metadata.description
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
                headers: [
                    "Accept": "\(episode.transcriptType ?? "text/plain"),text/plain;q=0.9,*/*;q=0.1"
                ],
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
            let generated = try await transcribe(mediaURL)
            guard !generated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeInputError.unreadableContent
            }
            transcript = generated
            transcriptError = nil
        } catch {
            transcriptError = error.localizedDescription
        }
    }
    let content: String
    if let transcript {
        content = "Transcript:\n\(transcript.text)"
    } else {
        let reason = transcriptError?
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = reason.map {
            "Automatic transcription could not be completed: \($0)"
        } ?? "Automatic transcription was not available for this episode."
        content = [
            "Transcript unavailable for this podcast episode.",
            status,
            episode.description.map { "\nDescription:\n\($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
    }
    return ItemDraft(
        inputID: .podcast,
        title: episode.title ?? showTitle ?? pageMetadata?.title ?? "Podcast episode",
        content: content,
        sourceURL: url,
        canonicalURL: episode.link ?? url,
        mediaURL: episode.mediaURL,
        faviconURL: pageMetadata?.faviconURL ??
            URL(string: "/favicon.ico", relativeTo: episode.link ?? url)?.absoluteURL,
        transcriptAvailable: transcript != nil,
        transcriptLanguage: transcript?.language,
        transcriptError: transcriptError
    )
}
