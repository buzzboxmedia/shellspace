import Foundation
import os.log

class ClaudeAPI {
    static let shared = ClaudeAPI()
    private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "ClaudeAPI")

    private var apiKey: String? {
        // Try environment variable first
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            logger.info("Using API key from environment variable")
            return key
        }
        // Then try UserDefaults
        if let key = UserDefaults.standard.string(forKey: "anthropic_api_key"), !key.isEmpty {
            logger.info("Using API key from UserDefaults")
            return key
        }
        logger.warning("No API key found in environment or UserDefaults")
        return nil
    }

    func summarizeChat(content: String, completion: @escaping (String?) -> Void) {
        logger.info("summarizeChat called with \(content.count) characters")

        guard let apiKey = apiKey else {
            logger.error("No Anthropic API key found - cannot summarize")
            completion(nil)
            return
        }

        guard !content.isEmpty else {
            logger.warning("Empty content provided - skipping summarization")
            completion(nil)
            return
        }

        // Truncate content if too long
        let truncatedContent = String(content.prefix(4000))
        logger.info("Truncated content to \(truncatedContent.count) characters")

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let prompt = """
        Based on this terminal session with Claude, generate a very short title (3-6 words) that describes what the conversation is about. Just respond with the title, nothing else.

        Terminal content:
        \(truncatedContent)
        """

        let body: [String: Any] = [
            "model": "claude-3-haiku-20240307",
            "max_tokens": 50,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            logger.info("Request body serialized successfully")
        } catch {
            logger.error("Failed to serialize request: \(error.localizedDescription)")
            completion(nil)
            return
        }

        logger.info("Sending API request to Anthropic...")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.logger.error("API request failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self?.logger.info("API response status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                self?.logger.error("No data received from API")
                completion(nil)
                return
            }

            self?.logger.info("Received \(data.count) bytes from API")

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String {
                    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.logger.info("Successfully extracted title: '\(title)'")
                    DispatchQueue.main.async {
                        completion(title)
                    }
                } else {
                    if let jsonString = String(data: data, encoding: .utf8) {
                        self?.logger.error("Unexpected API response format: \(jsonString.prefix(500))")
                    }
                    completion(nil)
                }
            } catch {
                self?.logger.error("Failed to parse API response: \(error.localizedDescription)")
                completion(nil)
            }
        }.resume()
    }

    /// Generate a short title from user's first input
    func generateTitle(from userInput: String, completion: @escaping (String?) -> Void) {
        logger.info("generateTitle called with: '\(userInput.prefix(100))'")

        guard let apiKey = apiKey else {
            logger.error("No Anthropic API key found - cannot generate title")
            completion(nil)
            return
        }

        guard !userInput.isEmpty else {
            logger.warning("Empty input provided - skipping title generation")
            completion(nil)
            return
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let prompt = """
        Generate a very short title (3-6 words) for this task or question. Just respond with the title, nothing else. Make it descriptive and action-oriented.

        User's input:
        \(userInput.prefix(500))
        """

        let body: [String: Any] = [
            "model": "claude-3-haiku-20240307",
            "max_tokens": 30,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize request: \(error.localizedDescription)")
            completion(nil)
            return
        }

        logger.info("Sending title generation request...")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.logger.error("API request failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data else {
                self?.logger.error("No data received from API")
                completion(nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String {
                    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.logger.info("Generated title: '\(title)'")
                    DispatchQueue.main.async {
                        completion(title)
                    }
                } else {
                    self?.logger.error("Unexpected API response format")
                    completion(nil)
                }
            } catch {
                self?.logger.error("Failed to parse API response: \(error.localizedDescription)")
                completion(nil)
            }
        }.resume()
    }

    func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "anthropic_api_key")
    }

    var hasAPIKey: Bool {
        apiKey != nil
    }
}
