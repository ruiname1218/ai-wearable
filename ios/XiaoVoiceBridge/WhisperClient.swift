import Foundation
import AVFoundation

/// Client for interacting with OpenAI's Whisper API.
class WhisperClient {
    static let shared = WhisperClient()
    
    private var apiKey: String {
        let defaultKey = "OPEN_API_KEY"
        let saved = UserDefaults.standard.string(forKey: "openaiApiKey")
        return (saved == nil || saved!.isEmpty) ? defaultKey : saved!
    }
    
    private init() {}
    
    /// Transcribe PCM samples to text using OpenAI Whisper API.
    /// - Parameters:
    ///   - samples: Raw Float PCM samples
    ///   - sampleRate: The sample rate of the audio (e.g., 16000)
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        // Enforce a minimum duration (e.g., 0.5 seconds) to prevent hallucinations
        let duration = Double(samples.count) / Double(sampleRate)
        print("🎙️ WhisperClient: Transcribing \(samples.count) samples (\(String(format: "%.2f", duration))s) at \(sampleRate)Hz")
        if duration < 0.5 {
            print("🎙️ WhisperClient: Audio too short, rejecting.")
            throw WhisperError.audioTooShort
        }
        
        let wavData = try createWAVData(from: samples, sampleRate: sampleRate)
        print("🎙️ WhisperClient: Created WAV data: \(wavData.count) bytes")
        return try await sendWhisperRequest(audioData: wavData)
    }
    
    private func sendWhisperRequest(audioData: Data) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw WhisperError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Model parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Language parameter (forces Japanese/English context to prevent Arabic hallucinations on noise)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("ja\r\n".data(using: .utf8)!)
        
        // File parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("🎙️ WhisperClient: Sending POST request to OpenAI...")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🎙️ WhisperClient: Invalid HTTP response")
            throw WhisperError.invalidResponse
        }
        
        print("🎙️ WhisperClient: Received response with status \(httpResponse.statusCode)")
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("🎙️ WhisperClient: Failed to parse JSON. Raw data: \(String(data: data, encoding: .utf8) ?? "")")
            throw WhisperError.invalidJSON
        }
        
        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
            print("🎙️ WhisperClient: API Error: \(msg)")
            throw WhisperError.apiError(msg)
        }
        
        guard httpResponse.statusCode == 200, let text = json["text"] as? String else {
            print("🎙️ WhisperClient: Processing Error HTTP \(httpResponse.statusCode)")
            throw WhisperError.httpError(httpResponse.statusCode)
        }
        
        // Filter out common hallucinations if it slipped through validation
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallucinations = ["ご視聴ありがとうございました", "サブタイトル:", "字幕:", ""]
        if hallucinations.contains(where: { trimmed.contains($0) }) {
            print("🎙️ WhisperClient: Hallucination detected and silenced: '\(trimmed)'")
            throw WhisperError.hallucinationDetected
        }
        
        print("🎙️ WhisperClient: Success: '\(trimmed)'")
        return text
    }
    
    /// Converts Float PCM array to properly formatted WAV file data
    private func createWAVData(from samples: [Float], sampleRate: Int) throws -> Data {
        let channels = 1
        let bitDepth = 16
        
        // Convert Float [-1.0, 1.0] to Int16
        var int16Samples = [Int16]()
        int16Samples.reserveCapacity(samples.count)
        for sample in samples {
            // Clamp and scale
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples.append(Int16(clamped * 32767.0))
        }
        
        let pcmData = int16Samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        var wavData = Data()
        
        // RIFF header
        wavData.append("RIFF".data(using: .utf8)!)
        let fileSize: UInt32 = UInt32(36 + pcmData.count)
        wavData.append(withUnsafeBytes(of: fileSize) { Data($0) })
        wavData.append("WAVE".data(using: .utf8)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .utf8)!)
        let chunkSize: UInt32 = 16
        wavData.append(withUnsafeBytes(of: chunkSize) { Data($0) })
        let audioFormat: UInt16 = 1 // PCM
        wavData.append(withUnsafeBytes(of: audioFormat) { Data($0) })
        let numChannels: UInt16 = UInt16(channels)
        wavData.append(withUnsafeBytes(of: numChannels) { Data($0) })
        let sampleRate32: UInt32 = UInt32(sampleRate)
        wavData.append(withUnsafeBytes(of: sampleRate32) { Data($0) })
        let byteRate: UInt32 = UInt32(sampleRate * channels * (bitDepth / 8))
        wavData.append(withUnsafeBytes(of: byteRate) { Data($0) })
        let blockAlign: UInt16 = UInt16(channels * (bitDepth / 8))
        wavData.append(withUnsafeBytes(of: blockAlign) { Data($0) })
        let bitsPerSample: UInt16 = UInt16(bitDepth)
        wavData.append(withUnsafeBytes(of: bitsPerSample) { Data($0) })
        
        // data chunk
        wavData.append("data".data(using: .utf8)!)
        let dataSize: UInt32 = UInt32(pcmData.count)
        wavData.append(withUnsafeBytes(of: dataSize) { Data($0) })
        wavData.append(pcmData)
        
        return wavData
    }
}

enum WhisperError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidJSON
    case httpError(Int)
    case apiError(String)
    case audioTooShort
    case hallucinationDetected
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURL"
        case .invalidResponse: return "無効なレスポンス"
        case .invalidJSON: return "JSON解析エラー"
        case .httpError(let code): return "HTTPエラー \(code)"
        case .apiError(let msg): return "Whisper APIエラー: \(msg)"
        case .audioTooShort: return "音声が短すぎます（ノイズ）"
        case .hallucinationDetected: return "無音時の幻覚を破棄しました"
        }
    }
}
