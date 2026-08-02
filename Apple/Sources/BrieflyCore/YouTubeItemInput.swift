import Foundation

func ingestYouTube(
    _ request: ItemInputRequest,
    context: ItemInputContext
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let videoID = youtubeVideoID(url) else { throw NativeInputError.unsupportedInput }
    let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    let body = try JSONSerialization.data(withJSONObject: [
        "context": ["client": [
            "clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple",
            "deviceModel": "iPhone16,2", "hl": "en", "osName": "iPhone",
            "osVersion": "18.3.2.22D82"
        ]],
        "videoId": videoID
    ])
    let response = try await context.http.post(endpoint, body: body, headers: [
        "Content-Type": "application/json",
        "User-Agent": "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        "X-YouTube-Client-Name": "5",
        "X-YouTube-Client-Version": "21.26.4"
    ], maximumBytes: 10_000_000)
    guard
        let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let video = payload["videoDetails"] as? [String: Any]
    else { throw NativeInputError.unreadableContent }
    let title = cleanInputText(video["title"] as? String) ?? "YouTube video \(videoID)"
    let author = cleanInputText(video["author"] as? String)
    let description = cleanInputText(video["shortDescription"] as? String)
    let captions = payload["captions"] as? [String: Any]
    let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
    let tracks = renderer?["captionTracks"] as? [[String: Any]] ?? []
    let formats = (payload["streamingData"] as? [String: Any])?["adaptiveFormats"]
        as? [[String: Any]] ?? []
    let audioURL = formats.first(where: {
        ($0["mimeType"] as? String)?.lowercased().hasPrefix("audio/") == true &&
            $0["url"] is String
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
            transcript = try await transcribe(audioURL ?? url)
            transcriptError = nil
        } catch {
            transcriptError = error.localizedDescription
        }
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
        faviconURL: URL(string: "https://www.youtube.com/favicon.ico"),
        audioSourceURL: audioURL,
        transcriptAvailable: transcript != nil,
        transcriptLanguage: transcript?.language,
        transcriptError: transcriptError
    )
}

func preferredYouTubeTrack(_ tracks: [[String: Any]]) -> [String: Any]? {
    tracks.first(where: {
        ($0["languageCode"] as? String)?.lowercased().hasPrefix("en") == true &&
            ($0["kind"] as? String) != "asr"
    }) ?? tracks.first(where: {
        ($0["languageCode"] as? String)?.lowercased().hasPrefix("en") == true
    }) ?? tracks.first
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
    let response = try await http.get(url, maximumBytes: 8_000_000)
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let events = object["events"] as? [[String: Any]] else {
        throw NativeInputError.unreadableContent
    }
    let lines = events.compactMap { event -> String? in
        let segments = event["segs"] as? [[String: Any]] ?? []
        return cleanInputText(segments.compactMap { $0["utf8"] as? String }.joined())
    }
    let text = lines.joined(separator: "\n")
    guard !text.isEmpty else { throw NativeInputError.unreadableContent }
    return InputTranscript(text: text, language: language)
}
