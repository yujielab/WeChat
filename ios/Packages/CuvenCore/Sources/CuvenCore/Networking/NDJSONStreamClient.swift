import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - NDJSON Streaming Client for Search & Explain (/api/ai/explain, src/explain.js:261-349)

public struct CuvenExplainSource: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var url: String
    public var site: String
    public var snippet: String

    public init(id: Int, title: String, url: String, site: String, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.site = site
        self.snippet = snippet
    }
}

public enum CuvenExplainStreamEvent: Equatable, Sendable {
    case stage(String)                              // "plan" | "search" | "compare" | "answer"
    case queries(queries: [String], language: String)
    case sources([CuvenExplainSource])
    case notice(String)                             // "no-search" | "search-failed"
    case delta(String)                              // Incremental answer chunk
    case followups([String])
    case done
    case error(String)
}

public struct NDJSONLineParser: Sendable {
    private var buffer: String = ""

    public init() {}

    /// Feeds an incremental UTF-8 chunk and returns all complete parsed `CuvenExplainStreamEvent` frames.
    public mutating func append(_ chunk: String) -> [CuvenExplainStreamEvent] {
        buffer.append(chunk)
        var events: [CuvenExplainStreamEvent] = []
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty, let event = Self.parseLine(line) {
                events.append(event)
            }
        }
        return events
    }

    public mutating func flush() -> [CuvenExplainStreamEvent] {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: false)
        guard !remaining.isEmpty, let event = Self.parseLine(remaining) else {
            return []
        }
        return [event]
    }

    public static func parseLine(_ line: String) -> CuvenExplainStreamEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: CuvenJSONValue].self, from: data),
              let type = obj["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "stage":
            return .stage(obj["stage"]?.stringValue ?? "answer")
        case "queries":
            let queries = obj["queries"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let lang = obj["lang"]?.stringValue ?? "en"
            return .queries(queries: queries, language: lang)
        case "sources":
            let sources: [CuvenExplainSource] = (obj["sources"]?.arrayValue ?? []).compactMap { item in
                guard let s = item.objectValue,
                      let id = s["id"]?.intValue,
                      let url = s["url"]?.stringValue else { return nil }
                return CuvenExplainSource(
                    id: id,
                    title: s["title"]?.stringValue ?? url,
                    url: url,
                    site: s["site"]?.stringValue ?? "",
                    snippet: s["snippet"]?.stringValue ?? ""
                )
            }
            return .sources(sources)
        case "notice":
            return .notice(obj["notice"]?.stringValue ?? "")
        case "delta":
            return .delta(obj["text"]?.stringValue ?? "")
        case "followups":
            let questions = obj["questions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .followups(questions)
        case "done":
            return .done
        case "error":
            return .error(obj["error"]?.stringValue ?? "Explain failed")
        default:
            return nil
        }
    }
}

public struct NDJSONStreamClient: Sendable {
    public let apiClient: CuvenAPIClient

    public init(apiClient: CuvenAPIClient) {
        self.apiClient = apiClient
    }

    /// Streams typed NDJSON explain events from `POST /api/ai/explain`.
    public func streamExplainEvents(
        selectedText: String,
        context: String,
        followUpQuestion: String? = nil,
        history: [(question: String, answer: String)] = []
    ) -> AsyncThrowingStream<CuvenExplainStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var payload: [String: CuvenJSONValue] = [
                        "text": .string(String(selectedText.prefix(300))),
                        "context": .string(String(context.prefix(1200)))
                    ]
                    if let q = followUpQuestion, !q.isEmpty {
                        payload["question"] = .string(String(q.prefix(300)))
                    }
                    if !history.isEmpty {
                        payload["history"] = .array(
                            history.suffix(3).map { item in
                                .object([
                                    "q": .string(String(item.question.prefix(300))),
                                    "a": .string(String(item.answer.prefix(2000)))
                                ])
                            }
                        )
                    }

                    let bodyData = try JSONEncoder().encode(payload)
                    let request = try await apiClient.buildRequest(
                        method: "POST",
                        path: "/api/ai/explain",
                        contentType: "application/json",
                        body: bodyData
                    )

                    #if canImport(FoundationNetworking)
                    let (data, response) = try await apiClient.performRawRequest(request)
                    if response.statusCode >= 400 {
                        throw CuvenAPIError(message: "Explain failed (\(response.statusCode))", statusCode: response.statusCode)
                    }
                    var parser = NDJSONLineParser()
                    let text = String(decoding: data, as: UTF8.self)
                    for event in parser.append(text) + parser.flush() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                    #else
                    let (bytes, urlResponse) = try await URLSession.shared.bytes(for: request)
                    if let http = urlResponse as? HTTPURLResponse, http.statusCode >= 400 {
                        throw CuvenAPIError(message: "Explain failed (\(http.statusCode))", statusCode: http.statusCode)
                    }
                    var parser = NDJSONLineParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        for event in parser.append(line + "\n") {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.flush() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
