import AVFoundation
import Combine
import CoreBluetooth
import Foundation
import Speech
#if canImport(UIKit)
import UIKit
#endif

final class BluetoothSpeechViewModel: NSObject, ObservableObject {
    @Published var bluetoothStatus: String = "Bluetooth初期化中..."
    @Published var speechStatus: String = "Whisper API 待機中"
    @Published var devices: [CBPeripheral] = []
    @Published var connectedDeviceName: String = "未接続"
    @Published var isConnected: Bool = false
    @Published var isBleAudioReady: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isAvatarActive: Bool = false // controls UI overlay
    @Published var transcript: String = ""
    @Published var liveTranscript: String = ""  // current partial recognition only
    @Published var vadState: String = "待機中"
    @Published var packetCount: Int = 0
    @Published var droppedPacketEstimate: Int = 0
    @Published var audioLevelRMS: Float = 0
    @Published var errorMessage: String = ""
    @Published var transferStatus: String = "待機中"
    @Published var appLifecycleStatus: String = "前面"
    @Published var autoConnectEnabled: Bool = true
    @Published var aiResponses: [AIResponseEntry] = []
    @Published var isProcessingAI: Bool = false

    struct AIResponseEntry: Identifiable {
        let id = UUID()
        let userMessage: String
        var aiReply: String
        var isLoading: Bool
        var isError: Bool
    }

    // Friend-compatible UUIDs
    private let audioServiceUUID = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    private let audioDataCharUUID = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    private let audioFormatCharUUID = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")

    // Friend transport packet header size: [packetIdLE(2), chunkIndex(1)]
    private let transportHeaderBytes = 3

    // Friend codec IDs
    private let codecPCM16_16K: UInt8 = 0
    private let codecPCM16_8K: UInt8 = 1

    private let recognitionSampleRate: Double = 16_000
    private lazy var recognitionAudioFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: recognitionSampleRate, channels: 1, interleaved: false)!
    }()

    private var centralManager: CBCentralManager!
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var audioDataCharacteristic: CBCharacteristic?
    private var audioFormatCharacteristic: CBCharacteristic?
    private var isAudioNotifyEnabled: Bool = false

    // Auto-connect
    private let savedDeviceUUIDKey = "com.xiao.voicebridge.savedDeviceUUID"
    private var reconnectTimer: Timer?
    private var autoStreamPending: Bool = false

    // OpenClaw Events Polling
    private var eventPollTimer: Timer?
    private var lastEventTimestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    // Voice activity detection / sentence segmentation
    private enum VADPhase { case waiting, speaking, silence }
    private let voiceOnThreshold: Float = 0.015  // Lowered from 0.025 to increase sensitivity
    private let voiceOffThreshold: Float = 0.010 // Lowered from 0.015
    private let silenceDuration: TimeInterval = 2.0
    private let voiceHoldover: TimeInterval = 1.0  // stay in speaking at least 1s after last voice
    private let rmsWindowSize: Int = 45  // Average over a slightly larger window to ignore sharp, short noises
    private var currentVADPhase: VADPhase = .waiting
    private var silenceTimer: Timer?
    private var finalizedSentences: [String] = []
    private var currentPartialText: String = ""
    private var smoothedRMS: Float = 0
    private var rmsHistory: [Float] = []
    private var lastVoiceTime: Date = .distantPast
    private var highPassPrevInput: Float = 0
    private var highPassPrevOutput: Float = 0
    private var recognitionSessionID: Int = 0  // incremented each session, used to ignore stale callbacks

    // Pre-buffer: stores recent audio so speech onset is not lost when VAD triggers
    private var preBuffer: [[Float]] = []  // each element is one packet's worth of samples
    private let preBufferMaxDuration: TimeInterval = 0.5  // keep last 0.5 seconds
    private var preBufferSampleCount: Int = 0

    // Buffer for the current active speech session
    private var currentSpeechBuffer: [Float] = []

    // Local Apple Speech for Noise Filtering
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var activeStreamSessionID: UUID?

    private var currentCodecID: UInt8 = 1
    private var currentSourceSampleRate: Double = 8_000
    private var pendingPCMByte: UInt8?
    private var lastPacketID: UInt16?
    private var lastChunkIndex: UInt8?
    private var isAppInBackground: Bool = false
#if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif
    private var needsRecognitionRecoveryOnForeground: Bool = false

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.xiao.voicebridge.central"]
        )
        
        startEventPolling()
    }
    
    // MARK: - OpenClaw Asynchronous Event Polling
    
    private func startEventPolling() {
        eventPollTimer?.invalidate()
        // Initialize timestamp to roughly now, minus a few seconds to catch immediate boot events
        lastEventTimestamp = Int64(Date().timeIntervalSince1970 * 1000) - 5000
        
        eventPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollEvents()
        }
    }
    
    private func pollEvents() {
        Task {
            do {
                let newEvents = try await OpenClawClient.shared.fetchEvents(since: self.lastEventTimestamp)
                if !newEvents.isEmpty {
                    await MainActor.run {
                        for event in newEvents {
                            // Update timestamp so we don't fetch this again
                            if event.timestamp > self.lastEventTimestamp {
                                self.lastEventTimestamp = event.timestamp
                            }
                            
                            // Append the event text as a new message from the AI
                            let entry = AIResponseEntry(userMessage: "通知 (Agent)", aiReply: event.text, isLoading: false, isError: false)
                            self.aiResponses.append(entry)
                        }
                    }
                }
            } catch {
                // Silently fail polling errors to avoid log spam
            }
        }
    }

    func setAppIsInBackground(_ inBackground: Bool) {
        guard isAppInBackground != inBackground else { return }
        isAppInBackground = inBackground
        appLifecycleStatus = inBackground ? "バックグラウンド" : "前面"

        if inBackground {
            if isStreaming {
                transferStatus = "バックグラウンド受信中..."
            }
        }
    }

    func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.speechAuthStatus = status
                switch status {
                case .authorized:
                    self.speechStatus = "音声認識: 許可済み (Whisper連携)"
                case .denied:
                    self.speechStatus = "音声認識: 許可拒否"
                case .restricted:
                    self.speechStatus = "音声認識: 利用制限"
                case .notDetermined:
                    self.speechStatus = "音声認識: 未決定"
                @unknown default:
                    self.speechStatus = "音声認識: 不明"
                }
            }
        }
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            bluetoothStatus = "BluetoothがOFFです"
            return
        }

        knownPeripherals.removeAll()
        devices.removeAll()
        centralManager.scanForPeripherals(withServices: [audioServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        bluetoothStatus = "Friend互換デバイスをスキャン中..."
    }

    func stopScan() {
        centralManager.stopScan()
        bluetoothStatus = isConnected ? "接続済み" : "スキャン停止"
    }

    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        bluetoothStatus = "\(peripheral.name ?? "Unknown") に接続中..."
        centralManager.connect(
            peripheral,
            options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ]
        )
    }

    func disconnect() {
        stopStreaming()
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func startStreaming() {
        guard isConnected, connectedPeripheral != nil else {
            errorMessage = "BLE接続後に開始してください"
            return
        }
        guard isBleAudioReady, audioDataCharacteristic != nil else {
            errorMessage = "音声Characteristicの準備中です。2〜3秒待って再度開始してください"
            return
        }
        guard speechAuthStatus == .authorized else {
            errorMessage = "iPhone側で音声認識の許可が必要です（設定 > プライバシー > 音声認識）"
            return
        }
        guard speechRecognizer?.isAvailable == true else {
            errorMessage = "ローカル音声認識器(SFSpeechRecognizer)が利用できません"
            return
        }
        guard currentCodecID == codecPCM16_16K || currentCodecID == codecPCM16_8K else {
            errorMessage = "未対応CODEC_ID: \(currentCodecID)（FriendのPCM設定を使用してください）"
            return
        }

        errorMessage = ""
        packetCount = 0
        droppedPacketEstimate = 0
        audioLevelRMS = 0
        pendingPCMByte = nil
        lastPacketID = nil
        lastChunkIndex = nil
        transferStatus = "受信開始 — 音声待ち"
        transcript = ""
        finalizedSentences.removeAll()
        currentPartialText = ""

        // Do NOT start recognition yet — wait for voice (VAD)
        currentVADPhase = .waiting
        vadState = "音声待ち..."
        isStreaming = true

        let sessionID = UUID()
        activeStreamSessionID = sessionID
        schedulePacketHealthCheck(for: sessionID)
    }

    func stopStreaming() {
        activeStreamSessionID = nil
        isStreaming = false
        transferStatus = "停止"
        pendingPCMByte = nil
        lastPacketID = nil
        lastChunkIndex = nil
        currentVADPhase = .waiting
        isAvatarActive = false
        vadState = "停止"
        silenceTimer?.invalidate()
        silenceTimer = nil
        resetVADState()
        stopSpeechBuffering()
#if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func startSpeechBuffering() {
        currentSpeechBuffer.removeAll(keepingCapacity: true)
        startRecognitionSession()
    }

    /// Flush the pre-buffer into the active speech buffer and recognizer.
    /// This ensures the beginning of speech (captured before VAD triggered) is not lost.
    private func flushPreBufferToCurrentSpeech() {
        for chunk in preBuffer {
            currentSpeechBuffer.append(contentsOf: chunk)
            appendFloatSamplesToRecognition(chunk, sourceSampleRate: currentSourceSampleRate)
        }
        preBuffer.removeAll(keepingCapacity: true)
        preBufferSampleCount = 0
    }

    private func stopSpeechBuffering() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        currentSpeechBuffer.removeAll(keepingCapacity: false)
        stopRecognitionSession()
    }

    private func startRecognitionSession() {
        // Clean up any previous task
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        // Increment session ID — callbacks from older sessions will be ignored
        recognitionSessionID += 1
        let mySessionID = recognitionSessionID

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard mySessionID == self.recognitionSessionID else { return }

                if let result {
                    self.currentPartialText = result.bestTranscription.formattedString
                    // We don't update display transcript here because Whisper will override it anyway
                }
            }
        }
    }

    private func stopRecognitionSession() {
        recognitionSessionID += 1
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }



    /// Reset all VAD signal processing state to prevent drift over time.
    private func resetVADState() {
        rmsHistory.removeAll(keepingCapacity: true)
        smoothedRMS = 0
        lastVoiceTime = .distantPast
        highPassPrevInput = 0
        highPassPrevOutput = 0
        preBuffer.removeAll(keepingCapacity: true)
        preBufferSampleCount = 0
    }

    private func updateDisplayTranscript() {
        liveTranscript = currentPartialText
        if finalizedSentences.isEmpty {
            transcript = currentPartialText
        } else {
            transcript = finalizedSentences.joined(separator: "\n") + (currentPartialText.isEmpty ? "" : "\n" + currentPartialText)
        }
    }

    private func finalizeCurrentSentence() {
        guard isStreaming else { return }
        
        let localDetectedText = currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Grab local copies for async processing
        let samples = currentSpeechBuffer
        let sampleRate = Int(currentSourceSampleRate)
        
        // Stop buffering and set phase to waiting, BUT keep avatar active so UI doesn't disappear
        stopSpeechBuffering()
        currentPartialText = ""
        currentVADPhase = .waiting
        resetVADState()
        
        // GATEKEEPER: If Apple Speech recognized absolutely NO words (empty string), it's just noise.
        guard !localDetectedText.isEmpty, !samples.isEmpty else {
            print("🗣️ VAD: Apple Speech detected no words. Classifying as noise. Discarding buffer.")
            isAvatarActive = false
            vadState = "音声待ち..."
            return
        }
        
        // Let UI know we are transmitting to Whisper API
        print("🗣️ VAD: Silence detected. Preparing to send \(samples.count) samples to Whisper API...")
        liveTranscript = ""
        isProcessingAI = true
        vadState = "Whisper処理中..."
        
        Task {
            do {
                print("🗣️ VAD: Calling WhisperClient.transcribe...")
                let text = try await WhisperClient.shared.transcribe(samples: samples, sampleRate: sampleRate)
                print("🗣️ VAD: Whisper API returned: '\(text)'")
                
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                await MainActor.run {
                    self.liveTranscript = ""
                    if !trimmed.isEmpty {
                        print("🗣️ VAD: Appending finalized sentence: '\(trimmed)'")
                        self.finalizedSentences.append(trimmed)
                        self.updateDisplayTranscript()
                        self.sendToOpenClaw(trimmed)
                    } else {
                        print("🗣️ VAD: Received empty string after trimming.")
                        self.isProcessingAI = self.aiResponses.contains { $0.isLoading }
                    }
                    self.isAvatarActive = false
                    self.vadState = "音声待ち..."
                }
            } catch WhisperError.audioTooShort, WhisperError.hallucinationDetected {
                // Ignore noise/hallucinations silently
                print("🗣️ VAD: Audio too short or hallucination detected. Ignoring.")
                await MainActor.run {
                    self.liveTranscript = ""
                    self.isProcessingAI = self.aiResponses.contains { $0.isLoading }
                    self.isAvatarActive = false
                    self.vadState = "音声待ち..."
                }
            } catch {
                print("🗣️ VAD: Exception calling Whisper API: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Whisper例外: \(error.localizedDescription)"
                    self.liveTranscript = ""
                    self.isProcessingAI = self.aiResponses.contains { $0.isLoading }
                    self.isAvatarActive = false
                    self.vadState = "音声待ち..."
                }
            }
        }
    }

    func sendManualMessage(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        finalizedSentences.append(text)
        sendToOpenClaw(text)
        updateDisplayTranscript()
    }

    private func sendToOpenClaw(_ message: String) {
        let entry = AIResponseEntry(userMessage: message, aiReply: "処理中...", isLoading: true, isError: false)
        aiResponses.append(entry)
        isProcessingAI = true
        let entryID = entry.id

        Task {
            do {
                let reply = try await OpenClawClient.shared.sendMessage(message)
                await MainActor.run {
                    if let index = self.aiResponses.firstIndex(where: { $0.id == entryID }) {
                        self.aiResponses[index].aiReply = reply
                        self.aiResponses[index].isLoading = false
                    }
                    self.isProcessingAI = self.aiResponses.contains { $0.isLoading }
                }
            } catch {
                await MainActor.run {
                    if let index = self.aiResponses.firstIndex(where: { $0.id == entryID }) {
                        self.aiResponses[index].aiReply = "エラー: \(error.localizedDescription)"
                        self.aiResponses[index].isLoading = false
                        self.aiResponses[index].isError = true
                    }
                    self.isProcessingAI = self.aiResponses.contains { $0.isLoading }
                }
            }
        }
    }

    /// VAD state machine using time-based approach for stability.
    /// Instead of counting frames, we track when voice was last heard
    /// and use a sliding window average to smooth out speech fluctuations.
    private func processVAD(rms: Float) {
        guard isStreaming else { return }

        // Update sliding window
        rmsHistory.append(rms)
        if rmsHistory.count > rmsWindowSize {
            rmsHistory.removeFirst()
        }
        let windowAvg = rmsHistory.reduce(0, +) / Float(rmsHistory.count)

        // Track last time voice-level energy was detected
        if windowAvg >= voiceOnThreshold {
            lastVoiceTime = Date()
        }

        let timeSinceVoice = Date().timeIntervalSince(lastVoiceTime)

        switch currentVADPhase {
        case .waiting:
            // Start speaking: window average must be above threshold
            if windowAvg >= voiceOnThreshold {
                currentVADPhase = .speaking
                isAvatarActive = true
                vadState = "🎙 音声録音中..."
                transferStatus = "音声検出 — バッファリング開始"
                errorMessage = ""
                startSpeechBuffering()
                flushPreBufferToCurrentSpeech()
            }

        case .speaking:
            // Only consider silence after holdover period
            if timeSinceVoice >= voiceHoldover && windowAvg < voiceOffThreshold {
                currentVADPhase = .silence
                vadState = "⏸ 無音検出..."
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDuration, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.silenceTimer = nil
                        self?.finalizeCurrentSentence()
                    }
                }
            }

        case .silence:
            // Resume speaking if voice returns
            if windowAvg >= voiceOnThreshold {
                silenceTimer?.invalidate()
                silenceTimer = nil
                currentVADPhase = .speaking
                vadState = "🎙 認識中..."
            }
        }
    }

    private func configureSpeechAudioSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "AudioSession設定失敗: \(error.localizedDescription)"
        }
#endif
    }

    private func deactivateSpeechAudioSession() {
#if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Deactivation failure is non-fatal for this prototype.
        }
#endif
    }

    private func updateBleAudioReadiness() {
        let wasReady = isBleAudioReady
        isBleAudioReady = isConnected && audioDataCharacteristic != nil && audioFormatCharacteristic != nil && isAudioNotifyEnabled
        // Auto-start streaming when BLE audio becomes ready
        if !wasReady && isBleAudioReady && autoConnectEnabled && !isStreaming {
            autoStreamPending = true
            tryAutoStartStreaming()
        }
    }

    private func tryAutoStartStreaming() {
        guard autoStreamPending, isBleAudioReady, !isStreaming else { return }
        autoStreamPending = false
        startStreaming()
    }

    private func saveDeviceUUID(_ uuid: UUID) {
        UserDefaults.standard.set(uuid.uuidString, forKey: savedDeviceUUIDKey)
    }

    private func loadSavedDeviceUUID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: savedDeviceUUIDKey) else { return nil }
        return UUID(uuidString: str)
    }

    private func startAutoScan() {
        guard autoConnectEnabled, !isConnected else { return }
        guard centralManager.state == .poweredOn else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        knownPeripherals.removeAll()
        devices.removeAll()
        centralManager.scanForPeripherals(withServices: [audioServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        bluetoothStatus = "自動スキャン中..."
    }

    private func scheduleReconnect() {
        guard autoConnectEnabled, !isConnected else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.startAutoScan()
        }
    }

    private func schedulePacketHealthCheck(for sessionID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            guard self.isStreaming, self.activeStreamSessionID == sessionID else { return }
            if self.packetCount == 0 {
                self.errorMessage = "音声パケットを受信できていません。ファームを書き込み直し、再接続してください"
                self.transferStatus = "受信失敗"
                self.stopStreaming()
            }
        }
    }

    private func applyCodecID(_ codecID: UInt8) {
        currentCodecID = codecID
        switch codecID {
        case codecPCM16_16K:
            currentSourceSampleRate = 16_000
            if !isStreaming {
                transferStatus = "待機中 (PCM16 16k)"
            }
        case codecPCM16_8K:
            currentSourceSampleRate = 8_000
            if !isStreaming {
                transferStatus = "待機中 (PCM16 8k)"
            }
        default:
            errorMessage = "未対応CODEC_ID: \(codecID)（PCMのみ対応）"
        }
    }

    private func updatePacketDropEstimate(packetID: UInt16, chunkIndex: UInt8) {
        guard let previousPacketID = lastPacketID, let previousChunkIndex = lastChunkIndex else {
            lastPacketID = packetID
            lastChunkIndex = chunkIndex
            return
        }

        if packetID == previousPacketID {
            let expectedChunk = previousChunkIndex &+ 1
            if chunkIndex != expectedChunk {
                droppedPacketEstimate += 1
            }
        } else {
            let packetGap = Int(packetID &- previousPacketID)
            if packetGap > 1 {
                droppedPacketEstimate += packetGap - 1
            }
            if chunkIndex > 0 {
                droppedPacketEstimate += Int(chunkIndex)
            }
        }

        lastPacketID = packetID
        lastChunkIndex = chunkIndex
    }



    /// Simple first-order high-pass filter (~300Hz cutoff at 8kHz sample rate)
    /// Removes low-frequency rumble, air conditioning hum, etc.
    private func applyHighPassFilter(_ samples: inout [Float]) {
        // alpha ≈ 0.94 for ~300Hz cutoff at 8kHz
        let alpha: Float = 0.94
        for i in 0..<samples.count {
            let input = samples[i]
            let output = alpha * (highPassPrevOutput + input - highPassPrevInput)
            highPassPrevInput = input
            highPassPrevOutput = output
            samples[i] = output
        }
    }

    private func decodePCMSamples(_ payload: ArraySlice<UInt8>) -> [Float] {
        var mergedBytes = [UInt8]()
        mergedBytes.reserveCapacity(payload.count + 1)

        if let pending = pendingPCMByte {
            mergedBytes.append(pending)
            pendingPCMByte = nil
        }
        mergedBytes.append(contentsOf: payload)

        if mergedBytes.count % 2 != 0, let last = mergedBytes.popLast() {
            pendingPCMByte = last
        }
        guard !mergedBytes.isEmpty else { return [] }

        var floatSamples = [Float]()
        floatSamples.reserveCapacity(mergedBytes.count / 2)

        var index = 0
        while index + 1 < mergedBytes.count {
            let littleEndian = UInt16(mergedBytes[index]) | (UInt16(mergedBytes[index + 1]) << 8)
            let sample = Int16(bitPattern: littleEndian)
            let normalized = Float(sample) / 32768.0
            floatSamples.append(normalized)
            index += 2
        }

        guard !floatSamples.isEmpty else { return floatSamples }

        // Apply high-pass filter to remove low-frequency ambient noise
        applyHighPassFilter(&floatSamples)

        // Compute RMS on filtered signal
        var sumSquares: Double = 0
        for s in floatSamples {
            sumSquares += Double(s * s)
        }
        let instantRMS = Float(sqrt(sumSquares / Double(floatSamples.count)))

        // Exponential moving average (heavy smoothing for stability)
        let smoothingFactor: Float = 0.1
        smoothedRMS = smoothingFactor * instantRMS + (1.0 - smoothingFactor) * smoothedRMS
        audioLevelRMS = smoothedRMS

        return floatSamples
    }

    private func appendFloatSamplesToRecognition(_ samples: [Float], sourceSampleRate: Double) {
        guard sourceSampleRate > 0, !samples.isEmpty, let recognitionRequest else { return }
        if samples.count == 1 {
            let frameCount = AVAudioFrameCount(1)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: recognitionAudioFormat, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            buffer.floatChannelData?[0][0] = samples[0]
            recognitionRequest.append(buffer)
            return
        }

        // Resample both up/down using linear interpolation.
        let durationSec = Double(samples.count - 1) / sourceSampleRate
        let outputCount = max(1, Int(durationSec * recognitionSampleRate) + 1)
        let frameCount = AVAudioFrameCount(outputCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: recognitionAudioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let maxInputIndex = samples.count - 1
        for outIndex in 0..<outputCount {
            let sourcePosition = Double(outIndex) * sourceSampleRate / recognitionSampleRate
            let leftIndex = min(maxInputIndex, Int(sourcePosition))
            let rightIndex = min(maxInputIndex, leftIndex + 1)
            let t = Float(sourcePosition - Double(leftIndex))
            let left = samples[leftIndex]
            let right = samples[rightIndex]
            channelData[outIndex] = left + (right - left) * t
        }

        recognitionRequest.append(buffer)
    }

    private func handleAudioPacket(_ data: Data) {
        guard isStreaming else { return }
        guard data.count > transportHeaderBytes else { return }

        let bytes = [UInt8](data)
        let packetID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let chunkIndex = bytes[2]
        let payload = bytes[transportHeaderBytes...]
        if payload.isEmpty { return }

        updatePacketDropEstimate(packetID: packetID, chunkIndex: chunkIndex)
        packetCount += 1

        guard currentCodecID == codecPCM16_16K || currentCodecID == codecPCM16_8K else {
            errorMessage = "未対応CODEC_ID: \(currentCodecID)"
            return
        }

        let samples = decodePCMSamples(payload)
        guard !samples.isEmpty else { return }

        // Always buffer recent audio for pre-buffer (used to capture speech onset)
        if currentVADPhase == .waiting {
            preBuffer.append(samples)
            preBufferSampleCount += samples.count
            // Trim to max duration
            let maxSamples = Int(preBufferMaxDuration * currentSourceSampleRate)
            while preBufferSampleCount > maxSamples && !preBuffer.isEmpty {
                preBufferSampleCount -= preBuffer.removeFirst().count
            }
        }

        // Feed audio to Whisper buffer and Apple Speech when actively speaking/silence
        if currentVADPhase == .speaking || currentVADPhase == .silence {
            currentSpeechBuffer.append(contentsOf: samples)
            appendFloatSamplesToRecognition(samples, sourceSampleRate: currentSourceSampleRate)
        }

        // VAD state machine
        processVAD(rms: audioLevelRMS)

        if currentVADPhase != .waiting {
            transferStatus = "受信中: \(packetCount) packets"
        }
    }
}

extension BluetoothSpeechViewModel: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            connectedDeviceName = peripheral.name ?? "Friend"
            isConnected = true
            bluetoothStatus = "接続復元: \(connectedDeviceName)"
            peripheral.discoverServices([audioServiceUUID])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth準備OK"
            // Auto-scan on Bluetooth ready
            if autoConnectEnabled && !isConnected {
                startAutoScan()
            }
        case .poweredOff:
            bluetoothStatus = "Bluetooth OFF"
        case .unauthorized:
            bluetoothStatus = "Bluetooth権限なし"
        case .unsupported:
            bluetoothStatus = "Bluetooth非対応"
        case .resetting:
            bluetoothStatus = "Bluetoothリセット中"
        case .unknown:
            bluetoothStatus = "Bluetooth状態不明"
        @unknown default:
            bluetoothStatus = "Bluetooth状態不明"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if knownPeripherals[peripheral.identifier] == nil {
            knownPeripherals[peripheral.identifier] = peripheral
            devices = knownPeripherals.values.sorted { lhs, rhs in
                (lhs.name ?? "") < (rhs.name ?? "")
            }
        }
        // Auto-connect: match saved UUID or device named "Friend"
        if autoConnectEnabled && !isConnected && connectedPeripheral == nil {
            let savedUUID = loadSavedDeviceUUID()
            let isSavedDevice = savedUUID != nil && peripheral.identifier == savedUUID
            let isFriendDevice = (peripheral.name ?? "").lowercased().contains("friend")
            if isSavedDevice || isFriendDevice {
                centralManager.stopScan()
                bluetoothStatus = "\(peripheral.name ?? "Friend") に自動接続中..."
                centralManager.connect(peripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([audioServiceUUID])
        bluetoothStatus = "\(peripheral.name ?? "Friend") に接続"
        connectedDeviceName = peripheral.name ?? "Friend"
        isConnected = true
        isAudioNotifyEnabled = false
        transferStatus = "サービス探索中"
        updateBleAudioReadiness()
        errorMessage = ""
        // Save device for auto-reconnect
        saveDeviceUUID(peripheral.identifier)
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        isBleAudioReady = false
        connectedDeviceName = "未接続"
        bluetoothStatus = "接続失敗"
        if let error {
            errorMessage = "接続エラー: \(error.localizedDescription)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        isBleAudioReady = false
        isStreaming = false
        connectedDeviceName = "未接続"
        bluetoothStatus = "切断されました"
        connectedPeripheral = nil
        audioDataCharacteristic = nil
        audioFormatCharacteristic = nil
        isAudioNotifyEnabled = false
        activeStreamSessionID = nil
        transferStatus = "切断"
        pendingPCMByte = nil
        lastPacketID = nil
        lastChunkIndex = nil
        stopSpeechBuffering()
        if let error {
            errorMessage = "切断エラー: \(error.localizedDescription)"
        }
        // Auto-reconnect
        scheduleReconnect()
    }
}

extension BluetoothSpeechViewModel: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            errorMessage = "Service発見失敗: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == audioServiceUUID {
            peripheral.discoverCharacteristics([audioDataCharUUID, audioFormatCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            errorMessage = "Characteristic発見失敗: \(error.localizedDescription)"
            return
        }
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            if characteristic.uuid == audioDataCharUUID {
                audioDataCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == audioFormatCharUUID {
                audioFormatCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            }
        }
        updateBleAudioReadiness()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            errorMessage = "Notify有効化失敗: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == audioDataCharUUID else { return }
        isAudioNotifyEnabled = characteristic.isNotifying
        updateBleAudioReadiness()
        if isAudioNotifyEnabled, !isStreaming {
            transferStatus = "待機中"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            errorMessage = "受信エラー: \(error.localizedDescription)"
            return
        }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == audioDataCharUUID {
            handleAudioPacket(data)
            return
        }
        if characteristic.uuid == audioFormatCharUUID, let codecID = data.first {
            applyCodecID(codecID)
        }
    }
}
