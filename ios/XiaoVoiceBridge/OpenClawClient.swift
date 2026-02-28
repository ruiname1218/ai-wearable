import Foundation

/// Client for the OpenClaw API running on Raspberry Pi via Tailscale.
final class OpenClawClient {
    static let shared = OpenClawClient()

    private let baseURL = "http://100.92.225.34:3000"
    private let appToken = "3ccfc6bbee7ff9e94481808eeada8702552206154bd550935ee4421811eba456"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600   // 10 minutes
        config.timeoutIntervalForResource = 3600  // 10 minutes
        session = URLSession(configuration: config)
    }

    /// Send a message to OpenClaw with automatic retry.
    /// Gateway timeouts (502/504) get extra-long delays since the server is likely still processing.
    func sendMessage(_ message: String, maxRetries: Int = 4) async throws -> String {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await sendRequest(message)
            } catch OpenClawError.invalidURL {
                throw OpenClawError.invalidURL // Don't retry bad URLs
            } catch OpenClawError.gatewayTimeout {
                // Server is processing but gateway gave up — wait longer before retry
                lastError = OpenClawError.gatewayTimeout
                if attempt < maxRetries - 1 {
                    let delays: [UInt64] = [5, 15, 30, 60] // seconds
                    let delay = delays[min(attempt, delays.count - 1)] * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 1s, 2s, 4s
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? OpenClawError.invalidResponse
    }

    private func sendRequest(_ message: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat") else {
            throw OpenClawError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["message": message]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenClawError.invalidResponse
        }

        // Detect gateway timeout before trying to parse JSON
        if httpResponse.statusCode == 502 || httpResponse.statusCode == 504 {
            throw OpenClawError.gatewayTimeout
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClawError.invalidJSON
        }

        if let errorMsg = json["error"] as? String {
            throw OpenClawError.apiError(errorMsg)
        }

        guard httpResponse.statusCode == 200, let reply = json["reply"] as? String else {
            throw OpenClawError.httpError(httpResponse.statusCode)
        }

        return reply
    }

    /// Check API health.
    func healthCheck() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

enum OpenClawError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidJSON
    case httpError(Int)
    case apiError(String)
    case gatewayTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "APIのURLが不正です"
        case .invalidResponse: return "APIからの応答が不正です"
        case .invalidJSON: return "JSON解析に失敗しました"
        case .httpError(let code): return "HTTPエラー: \(code)"
        case .apiError(let msg): return "APIエラー: \(msg)"
        case .gatewayTimeout: return "サーバー処理中にタイムアウト。リトライします..."
        }
    }
}
