import Foundation

class OllamaService {
    private let session = URLSession.shared

    private var baseURL: String {
        let configured = TOMLSettingsManager.shared.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "http://localhost:11434" : configured
    }

    private var model: String {
        let configured = TOMLSettingsManager.shared.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "llama3.2:latest" : configured
    }

    enum OllamaError: Error, LocalizedError {
        case invalidURL
        case noData
        case decodingError
        case networkError(String)
        case ollamaNotRunning

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Ollama URL"
            case .noData:
                return "No response data received"
            case .decodingError:
                return "Failed to decode response"
            case .networkError(let message):
                return "Network error: \(message)"
            case .ollamaNotRunning:
                return "Ollama is not running. Please start Ollama first."
            }
        }
    }

    // MARK: - Model Discovery

    struct InstalledModel: Decodable, Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    private struct TagsResponse: Decodable {
        let models: [InstalledModel]
    }

    /// Fetch the list of installed models from the configured Ollama server.
    /// Used by Settings to populate the model picker.
    func fetchInstalledModels() async throws -> [InstalledModel] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                throw OllamaError.ollamaNotRunning
            }

            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch let error as OllamaError {
            throw error
        } catch _ as DecodingError {
            throw OllamaError.decodingError
        } catch {
            throw OllamaError.ollamaNotRunning
        }
    }
    
    // MARK: - Public Interface

    /// The answer to `prompt` as it's generated, `system` in place of the
    /// model's own system prompt. Ending the stream (Stop,
    /// closing Find, leaving the tab) cancels the request, and Ollama stops
    /// generating.
    func streamAnswer(to prompt: String, system: String) async throws -> AsyncThrowingStream<String, Error> {
        try await checkOllamaStatus()

        let request = OllamaRequest(
            model: model,
            system: system,
            prompt: prompt,
            stream: true
        )

        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (asyncBytes, response) = try await session.bytes(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            throw OllamaError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    // A line at a time, each read as UTF-8 whole: a byte at a
                    // time, every letter outside ASCII came out as two wrong
                    // ones (å as Ã¥).
                    for try await line in asyncBytes.lines {
                        guard let data = line.data(using: .utf8),
                              let response = try? JSONDecoder().decode(OllamaResponse.self, from: data) else { continue }

                        if let error = response.error {
                            continuation.finish(throwing: OllamaError.networkError(error))
                            return
                        }

                        if let responseText = response.response {
                            continuation.yield(responseText)
                        }

                        if response.done == true {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reading.cancel()
            }
        }
    }

    /// An answer in the shape of `schema` (JSON Schema, as JSON), as JSON
    /// (Ollama's `format`).
    func generateStructured(system: String, prompt: String, schema: String) async throws -> String {
        try await checkOllamaStatus()
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }
        guard let format = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) else {
            throw OllamaError.decodingError
        }
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "format": format,
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A long list takes a local model a while
        urlRequest.timeoutInterval = 300
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                throw OllamaError.networkError("HTTP \(httpResponse.statusCode)")
            }
            let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
            if let error = ollamaResponse.error {
                throw OllamaError.networkError(error)
            }
            guard let text = ollamaResponse.response else { throw OllamaError.noData }
            return text
        } catch _ as DecodingError {
            throw OllamaError.decodingError
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func checkOllamaStatus() async throws {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw OllamaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        
        do {
            let (_, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                throw OllamaError.ollamaNotRunning
            }
        } catch {
            throw OllamaError.ollamaNotRunning
        }
    }
}
