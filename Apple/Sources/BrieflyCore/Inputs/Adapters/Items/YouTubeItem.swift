import Foundation

private let youtubePlayerEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

private struct YouTubeCaptionSegment {
    let startMilliseconds: Int
    let text: String
}

func ingestYouTube(
    _ request: ItemInputRequest,
    context: ItemInputContext
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let videoID = youtubeVideoID(url) else { throw NativeInputError.unsupportedInput }

    var player: [String: Any]?
    var playerError: Error?
    do {
        player = try await fetchYouTubePlayer(videoID: videoID, http: context.http)
    } catch {
        playerError = error
    }

    var pageResponse: InputHTTPResponse?
    var video = player?["videoDetails"] as? [String: Any]
    if video == nil {
        pageResponse = try? await context.http.get(url, maximumBytes: 20_000_000)
        if let pageResponse {
            player = extractYouTubePlayerResponse(pageResponse.text)
            video = player?["videoDetails"] as? [String: Any]
        }
    }

    let initialMicroformat = player?["microformat"] as? [String: Any]
    let microformat = initialMicroformat?["playerMicroformatRenderer"] as? [String: Any]
    var metadata = pageResponse.map { inputHTMLMetadata($0.text, baseURL: $0.finalURL) }
    let initialTitle = youtubeText(video?["title"])
    let initialDescription = youtubeText(video?["shortDescription"]) ??
        youtubeText((microformat?["description"] as? [String: Any]))

    // The player endpoint normally contains all metadata. Fetch the page only
    // when it does not, so a page-only fixture or a blocked player endpoint can
    // still yield a useful native capture.
    if pageResponse == nil, initialTitle == nil || initialDescription == nil ||
        youtubeCaptionTracks(in: player).isEmpty {
        pageResponse = try? await context.http.get(url, maximumBytes: 20_000_000)
        if let pageResponse {
            metadata = inputHTMLMetadata(pageResponse.text, baseURL: pageResponse.finalURL)
            if let pagePlayer = extractYouTubePlayerResponse(pageResponse.text) {
                if player == nil {
                    player = pagePlayer
                    video = pagePlayer["videoDetails"] as? [String: Any]
                } else if var existingPlayer = player {
                    if youtubeCaptionTracks(in: existingPlayer).isEmpty,
                       let captions = pagePlayer["captions"] {
                        existingPlayer["captions"] = captions
                    }
                    if existingPlayer["streamingData"] == nil,
                       let streamingData = pagePlayer["streamingData"] {
                        existingPlayer["streamingData"] = streamingData
                    }
                    player = existingPlayer
                }
            }
        }
    }

    let finalVideo = video ?? player?["videoDetails"] as? [String: Any]
    let finalMicroformat = (player?["microformat"] as? [String: Any]).flatMap {
        $0["playerMicroformatRenderer"] as? [String: Any]
    }
    let title = youtubeText(finalVideo?["title"]) ??
        metadata?.title ??
        "YouTube video \(videoID)"
    let author = youtubeText(finalVideo?["author"]) ??
        youtubeText(finalMicroformat?["ownerChannelName"])
    let description = youtubeText(finalVideo?["shortDescription"]) ??
        youtubeText(finalMicroformat?["description"] as? [String: Any]) ??
        metadata?.description

    var tracks = youtubeCaptionTracks(in: player)
    if tracks.contains(where: youtubeCaptionURLNeedsRefresh) {
        if let refreshed = try? await fetchYouTubeCaptionTracksWithoutProofToken(
            videoID: videoID,
            http: context.http
        ), !refreshed.isEmpty {
            tracks = refreshed
        }
    }

    let formats = (player?["streamingData"] as? [String: Any])?["adaptiveFormats"]
        as? [[String: Any]] ?? []
    let audioURL = formats.first(where: {
        ($0["mimeType"] as? String)?.lowercased().hasPrefix("audio/") == true &&
            httpInputURL($0["url"] as? String) != nil
    }).flatMap { httpInputURL($0["url"] as? String) }

    var transcript: InputTranscript?
    var transcriptError: String?
    if let track = preferredYouTubeTrack(tracks), let value = track["baseUrl"] as? String {
        do {
            transcript = try await fetchYouTubeTranscript(
                value,
                language: cleanInputText(track["languageCode"] as? String),
                http: context.http
            )
        } catch {
            transcriptError = error.localizedDescription
        }
    }
    if transcript == nil, let transcribe = context.transcribe {
        do {
            let generated = try await transcribe(audioURL ?? url)
            guard !generated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeInputError.unreadableContent
            }
            transcript = generated
            transcriptError = nil
        } catch {
            transcriptError = error.localizedDescription
        }
    }

    guard finalVideo != nil || metadata != nil || transcript != nil else {
        throw playerError ?? NativeInputError.unreadableContent
    }

    let content = transcript.map { "Transcript:\n\($0.text)" } ?? [
        "Transcript unavailable for this video.",
        author.map { "Channel: \($0)" },
        description.map { "\nDescription:\n\($0)" }
    ].compactMap { $0 }.joined(separator: "\n")
    return ItemDraft(
        inputID: .youtube,
        title: title,
        content: content,
        sourceURL: url,
        canonicalURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
        faviconURL: metadata?.faviconURL ?? URL(string: "https://www.youtube.com/favicon.ico"),
        audioSourceURL: audioURL,
        transcriptAvailable: transcript != nil,
        transcriptLanguage: transcript?.language,
        transcriptError: transcriptError
    )
}

private func fetchYouTubePlayer(
    videoID: String,
    http: InputHTTPClient
) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: [
        "context": ["client": [
            "clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple",
            "deviceModel": "iPhone16,2", "hl": "en", "osName": "iPhone",
            "osVersion": "18.3.2.22D82"
        ]],
        "videoId": videoID
    ])
    let response = try await http.post(youtubePlayerEndpoint, body: body, headers: [
        "Content-Type": "application/json",
        "User-Agent": "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        "X-YouTube-Client-Name": "5",
        "X-YouTube-Client-Version": "21.26.4"
    ], maximumBytes: 10_000_000)
    guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw NativeInputError.unreadableContent
    }
    return payload
}

private func fetchYouTubeCaptionTracksWithoutProofToken(
    videoID: String,
    http: InputHTTPClient
) async throws -> [[String: Any]] {
    let player = try await fetchYouTubePlayer(videoID: videoID, http: http)
    return youtubeCaptionTracks(in: player)
}

private func youtubeCaptionTracks(in player: [String: Any]?) -> [[String: Any]] {
    let captions = player?["captions"] as? [String: Any]
    let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
    return renderer?["captionTracks"] as? [[String: Any]] ?? []
}

func preferredYouTubeTrack(_ tracks: [[String: Any]]) -> [String: Any]? {
    tracks.enumerated()
        .filter { $0.element["baseUrl"] is String }
        .sorted {
            let left = youtubeTrackScore($0.element)
            let right = youtubeTrackScore($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }
        .first?.element
}

private func youtubeTrackScore(_ track: [String: Any]) -> Int {
    let language = cleanInputText(track["languageCode"] as? String)?.lowercased() ?? ""
    let english = language == "en" || language.hasPrefix("en-") ? 2 : 0
    return (track["kind"] as? String == "asr" ? 0 : 10) + english
}

private func youtubeCaptionURLNeedsRefresh(_ track: [String: Any]) -> Bool {
    guard let value = track["baseUrl"] as? String else { return false }
    return value.range(
        of: #"(?:[?&])exp=xp[ev](?:&|$)"#,
        options: .regularExpression
    ) != nil
}

func fetchYouTubeTranscript(
    _ rawURL: String,
    language: String?,
    http: InputHTTPClient
) async throws -> InputTranscript {
    guard var components = URLComponents(string: rawURL) else {
        throw NativeInputError.invalidResponse
    }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "fmt" }
    items.append(URLQueryItem(name: "fmt", value: "json3"))
    components.queryItems = items
    guard let url = components.url else { throw NativeInputError.invalidResponse }
    let response = try await http.get(
        url,
        headers: ["Accept": "application/json,text/xml;q=0.9,*/*;q=0.1"],
        maximumBytes: 10_000_000
    )
    let segments = parseYouTubeCaptionResponse(response.text)
    let text = segments.map(\.text).joined(separator: "\n")
    guard !text.isEmpty else { throw NativeInputError.unreadableContent }
    return InputTranscript(text: text, language: language)
}

private func parseYouTubeCaptionResponse(_ text: String) -> [YouTubeCaptionSegment] {
    if let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let events = object["events"] as? [[String: Any]] {
        return events.compactMap { event in
            let segments = event["segs"] as? [[String: Any]] ?? []
            let content = cleanInputText(
                segments.compactMap { $0["utf8"] as? String }.joined()
            )
            guard let content else { return nil }
            return YouTubeCaptionSegment(
                startMilliseconds: youtubeMilliseconds(event["tStartMs"]),
                text: content
            )
        }
    }

    guard let regex = try? NSRegularExpression(
        pattern: #"(?is)<text\b[^>]*\bstart\s*=\s*[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</text\s*>"#
    ) else { return [] }
    let range = NSRange(location: 0, length: text.utf16.count)
    return regex.matches(in: text, range: range).compactMap { match in
        guard let startRange = Range(match.range(at: 1), in: text),
              let contentRange = Range(match.range(at: 2), in: text) else { return nil }
        let content = cleanInputText(
            inputDecodeHTML(String(text[contentRange]))
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        )
        guard let content else { return nil }
        return YouTubeCaptionSegment(
            startMilliseconds: Int((Double(String(text[startRange])) ?? 0) * 1000),
            text: content
        )
    }
}

private func youtubeMilliseconds(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(Double(string) ?? 0) }
    return 0
}

func extractYouTubePlayerResponse(_ html: String) -> [String: Any]? {
    let patterns = [
        #"(?:var\s+)?ytInitialPlayerResponse\s*=\s*"#,
        #"\"ytInitialPlayerResponse\"\s*:\s*"#
    ]
    let range = NSRange(location: 0, length: html.utf16.count)
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        for match in regex.matches(in: html, range: range) {
            let offset = match.range.location + match.range.length
            guard offset < html.utf16.count else { continue }
            let afterMarker = String(html[String.Index(utf16Offset: offset, in: html)...])
            guard let opening = afterMarker.firstIndex(of: "{"),
                  afterMarker.distance(from: afterMarker.startIndex, to: opening) <= 20,
                  let serialized = balancedYouTubeJSONObject(
                    html,
                    opening: String.Index(
                        utf16Offset: offset + afterMarker[..<opening].utf16.count,
                        in: html
                    )
                  ),
                  let data = serialized.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object
        }
    }
    return nil
}

private func balancedYouTubeJSONObject(_ text: String, opening: String.Index) -> String? {
    var depth = 0
    var quoted = false
    var escaped = false
    var index = opening
    while index < text.endIndex {
        let character = text[index]
        if quoted {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted = false
            }
        } else if character == "\"" {
            quoted = true
        } else if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 { return String(text[opening...index]) }
        }
        index = text.index(after: index)
    }
    return nil
}

private func youtubeText(_ value: Any?) -> String? {
    if let value = value as? String { return cleanInputText(value) }
    guard let object = value as? [String: Any] else { return nil }
    if let simpleText = object["simpleText"] as? String {
        return cleanInputText(simpleText)
    }
    if let runs = object["runs"] as? [[String: Any]] {
        return cleanInputText(runs.compactMap { $0["text"] as? String }.joined())
    }
    return nil
}
