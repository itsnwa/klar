import Foundation

/// Search suggestions for what's typed, from the default search engine's
/// own suggestion service (`DefaultSearchEngine.suggestionsURL`).
class SearchSuggestionsService {
    static let shared = SearchSuggestionsService()
    
    private var activeTasks: Set<URLSessionDataTask> = []

    /// Tracks a query prefix that returned no results - queries starting with this prefix will be skipped
    private var exhaustedPrefix: String?

    private init() {}

    /// Reset the exhausted prefix tracking (call when starting a new search session)
    func resetExhaustedPrefix() {
        exhaustedPrefix = nil
    }
    
    /// Cancel all pending requests and reset exhausted prefix tracking
    func cancelAllRequests() {
        if !activeTasks.isEmpty {
            logDebug(.commandPalette, "Canceling \(activeTasks.count) pending search suggestion requests")
        }
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
        exhaustedPrefix = nil
    }
    
    /// Fetch search suggestions from the default engine. Requests still running for
    /// earlier queries are cancelled: only the latest one's are shown.
    func fetchSuggestions(for query: String, completion: @escaping @MainActor ([String]) -> Void) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !trimmedQuery.isEmpty else {
            completion([])
            return
        }

        // Check if this query starts with a prefix that already returned no results
        if let exhausted = exhaustedPrefix, trimmedQuery.hasPrefix(exhausted) {
            logDebug(.commandPalette, "Skipping search suggestions - query '\(trimmedQuery)' starts with exhausted prefix '\(exhausted)'")
            completion([])
            return
        }

        guard let url = TOMLSettingsManager.shared.defaultSearchEngine.suggestionsURL(for: query) else {
            logError(.commandPalette, "Failed to create the search suggestions URL")
            completion([])
            return
        }
        
        // On URLSession's queue: the response is read there, then handed to
        // the main actor.
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let outcome = Self.outcome(of: data, error: error, query: query)
            DispatchQueue.main.async {
                // Remove task from tracking when completion handler is called
                if let task = self?.activeTasks.first(where: { $0.originalRequest?.url == url }) {
                    self?.activeTasks.remove(task)
                }
                let result: [String]
                switch outcome {
                case .cancelled:
                    // Superseded by a newer query, or the palette closed: nothing to deliver.
                    return
                case .failed:
                    completion([])
                    return
                case .suggestions(let suggestions):
                    result = suggestions
                }
                // Update exhausted prefix tracking based on results
                if result.isEmpty {
                    // No results - mark this query as exhausted prefix
                    self?.exhaustedPrefix = trimmedQuery
                    logDebug(.commandPalette, "Marking '\(trimmedQuery)' as exhausted prefix - no search suggestions returned")
                } else {
                    // Got results - clear any exhausted prefix
                    self?.exhaustedPrefix = nil
                }
                completion(result)
            }
        }
        
        // Track the task, cancelling those for earlier queries
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
        activeTasks.insert(task)
        
        task.resume()
    }

    nonisolated private enum Outcome: Sendable {
        case cancelled
        case failed
        case suggestions([String])
    }

    /// What a response says.
    private nonisolated static func outcome(of data: Data?, error: Error?, query: String) -> Outcome {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        
        guard let data = data, error == nil else {
            if let error = error {
                logError(.commandPalette, "Search suggestions request failed: \(error.localizedDescription)")
            } else {
                logError(.commandPalette, "Search suggestions request failed with no data")
            }
            return .failed
        }
        
        // Parse the JSON response
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
               json.count >= 2,
               let suggestions = json[1] as? [String] {
                // Filter out the original query and limit to reasonable number
                return .suggestions(Array(suggestions
                    .filter { $0.lowercased() != query.lowercased() }
                    .prefix(8)))
            }
            logWarning(.commandPalette, "Search suggestions response format unexpected for query: '\(query)'")
            return .failed
        } catch {
            logError(.commandPalette, "Failed to parse search suggestions JSON: \(error.localizedDescription)")
            return .failed
        }
    }
} 
