import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: BluetoothSpeechViewModel
    @State private var showSettings = false
    @State private var manualInput: String = ""
    @AppStorage("openaiApiKey") private var openaiApiKey: String = ""

    var body: some View {
        ZStack {
            // Pure black background for the unified look
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Header
                headerView
                Divider().background(Color.white.opacity(0.1))
                
                // Chat Area
                chatArea
                
                Divider().background(Color.white.opacity(0.1))
                // Bottom Area (Controls)
                bottomArea
            }
            // Blur and fade the chat when avatar is active
            .blur(radius: viewModel.isAvatarActive ? 20 : 0)
            .opacity(viewModel.isAvatarActive ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: viewModel.isAvatarActive)
            
            // The prominent liquid metallic bubble overlay
            if viewModel.isAvatarActive {
                streamingOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: viewModel.isAvatarActive)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    // MARK: - Status Header

    private var headerView: some View {
        HStack {
            // Status marker
            Circle()
                .fill(viewModel.isConnected ? Color.white : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)

            Text(viewModel.isConnected ? viewModel.connectedDeviceName : "未接続")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(viewModel.isConnected ? .white : .gray)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    if viewModel.aiResponses.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "waveform")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.2))
                            Text("音声コマンドを待機中")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                    }

                    ForEach(viewModel.aiResponses) { entry in
                        VStack(spacing: 12) {
                            // User message
                            userBubble(entry.userMessage)

                            // AI response
                            aiBubble(entry)
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .onChange(of: viewModel.aiResponses.count) { _, _ in
                if let last = viewModel.aiResponses.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            // User side is right
            Spacer(minLength: 40)
            Text(text)
                .font(.body)
                .foregroundStyle(.black)
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func aiBubble(_ entry: BluetoothSpeechViewModel.AIResponseEntry) -> some View {
        HStack {
            if entry.isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                        .scaleEffect(0.9)
                    Text("思考中...")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            } else {
                Text(LocalizedStringKey(entry.aiReply))
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .tint(.blue) // URL highlight color
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(entry.isError ? Color.red.opacity(0.2) : Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(entry.isError ? Color.red.opacity(0.4) : Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
            Spacer(minLength: 40)
        }
    }

    // MARK: - Bottom Bar (Idle)

    private var bottomArea: some View {
        HStack(spacing: 12) {
            // Text Input Field
            TextField("コマンドを入力...", text: $manualInput)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .submitLabel(.send)
                .onSubmit {
                    if !manualInput.isEmpty {
                        viewModel.sendManualMessage(manualInput)
                        manualInput = ""
                    }
                }
                .disabled(viewModel.isAvatarActive)

            // Send or Mic Button
            Button {
                if !manualInput.isEmpty {
                    // Send text
                    viewModel.sendManualMessage(manualInput)
                    manualInput = ""
                } else {
                    // Start/Stop voice toggle
                    if viewModel.isStreaming {
                        viewModel.stopStreaming()
                    } else if viewModel.isConnected {
                        viewModel.startStreaming()
                    } else {
                        viewModel.startScan()
                    }
                }
            } label: {
                Image(systemName: manualInput.isEmpty ? (viewModel.isStreaming ? "stop.fill" : (viewModel.isConnected ? "mic.fill" : "antenna.radiowaves.left.and.right")) : "paperplane.fill")
                    .font(.title3)
                    .foregroundStyle(viewModel.isStreaming && manualInput.isEmpty ? .white : .black)
                    .frame(width: 44, height: 44)
                    .background(viewModel.isStreaming && manualInput.isEmpty ? Color.red : Color.white)
                    .clipShape(Circle())
            }
            .disabled(manualInput.isEmpty && viewModel.isConnected && !viewModel.isBleAudioReady)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    // MARK: - Streaming Overlay (The Avatar Interface)

    private var streamingOverlay: some View {
        VStack(spacing: 36) {
            Spacer()
            
            let isHearingVoice = viewModel.vadState.contains("認識中") || viewModel.vadState.contains("録音中")
            let isProcessing = viewModel.vadState.contains("処理中")
            
            Text(isProcessing ? "Thinking..." : (isHearingVoice ? "Listening..." : "Waiting..."))
                .font(.headline.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
            
            // Stunning 3D Liquid Metal Avatar
            LiquidMetalBubble(isSpeaking: isHearingVoice || isProcessing, rms: isProcessing ? 0.3 : viewModel.audioLevelRMS)
                .frame(width: 250, height: 250)
            
            // Text being spoken right now
            Text(viewModel.liveTranscript)
                .font(.system(size: 24, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(minHeight: 120, alignment: .top)
                .animation(.default, value: viewModel.liveTranscript)
            
            Spacer()
            
            Button {
                viewModel.stopStreaming()
            } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35)) // More transparent glass-like background
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("OpenAI API") {
                    SecureField("sk-xxxxxxxx...", text: $openaiApiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("接続") {
                    Toggle("自動接続", isOn: $viewModel.autoConnectEnabled)
                        .tint(.white)

                    HStack {
                        Text("Bluetooth")
                        Spacer()
                        Text(viewModel.bluetoothStatus)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    HStack {
                        Text("音声認識")
                        Spacer()
                        Text(viewModel.speechStatus)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    HStack {
                        Text("音声受信")
                        Spacer()
                        Text(viewModel.isBleAudioReady ? "準備OK" : "未完了")
                            .foregroundStyle(viewModel.isBleAudioReady ? .green : .white.opacity(0.5))
                    }
                }

                Section("統計") {
                    HStack {
                        Text("受信パケット")
                        Spacer()
                        Text("\(viewModel.packetCount)")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    HStack {
                        Text("音量RMS")
                        Spacer()
                        Text(String(format: "%.4f", viewModel.audioLevelRMS))
                            .foregroundStyle(.white.opacity(0.5))
                            .monospacedDigit()
                    }
                }

                if !viewModel.errorMessage.isEmpty {
                    Section("エラー") {
                        Text(viewModel.errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section("デバイス検索") {
                    if viewModel.devices.isEmpty {
                        Text("デバイスが見つかっていません")
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        ForEach(viewModel.devices, id: \.identifier) { peripheral in
                            Button {
                                viewModel.connect(to: peripheral)
                                showSettings = false
                            } label: {
                                HStack {
                                    Text(peripheral.name ?? "Unknown")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("接続")
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        showSettings = false
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - Liquid Metal Avatar View
//
// Uses the "metaball" technique: draw white circles on black,
// apply heavy Gaussian blur, then crank up contrast.
// Where blurred circles overlap, they merge into one smooth liquid blob.
// This creates authentic liquid surface-tension behavior.

struct LiquidMetalBubble: View {
    var isSpeaking: Bool
    var rms: Float

    // 6 independent blobs, each with unique Lissajous orbit parameters.
    // Using irrational frequency ratios ensures the pattern never repeats.
    private let blobs: [BlobParams] = [
        // (radiusFraction, xFreq, yFreq, xPhase, yPhase)
        BlobParams(radius: 0.18, xF: 1.0,   yF: 1.3,   xP: 0.0,  yP: 0.0),
        BlobParams(radius: 0.15, xF: 0.7,   yF: 1.0,   xP: 1.2,  yP: 0.8),
        BlobParams(radius: 0.20, xF: 1.1,   yF: 0.6,   xP: 2.5,  yP: 1.4),
        BlobParams(radius: 0.12, xF: 0.5,   yF: 1.4,   xP: 0.7,  yP: 3.1),
        BlobParams(radius: 0.16, xF: 1.3,   yF: 0.9,   xP: 3.8,  yP: 2.0),
        BlobParams(radius: 0.14, xF: 0.8,   yF: 1.2,   xP: 5.0,  yP: 4.2),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            // Slow, meditative speed — faster when speaking
            let t = now * (isSpeaking ? 0.35 : 0.12)
            // Voice amplitude gently expands the orbit range
            let voiceAmp: CGFloat = 1.0 + min(CGFloat(rms) * 1.5, 0.4)

            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: size / 2, y: size / 2)

                ZStack {
                    // ── Layer 1: Metaball liquid ──
                    // Draw circles on black → blur → contrast = liquid merging
                    Canvas { ctx, canvasSize in
                        for blob in blobs {
                            let r = blob.radius * size * voiceAmp
                            // Lissajous curve: x = sin(xF*t + xP), y = sin(yF*t + yP)
                            // Orbit radius scales with container, reduced to keep blobs inside sphere
                            let orbitR = size * 0.18 * voiceAmp
                            let x = center.x + CGFloat(sin(t * blob.xF + blob.xP)) * orbitR
                            let y = center.y + CGFloat(sin(t * blob.yF + blob.yP)) * orbitR
                            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                            ctx.fill(Ellipse().path(in: rect), with: .color(.white))
                        }
                    }
                    .frame(width: size, height: size)
                    // The magic: blur fuses nearby circles, contrast sharpens edges
                    // → creates authentic liquid surface tension
                    .blur(radius: size * 0.06)
                    .contrast(10)         // threshold: grey → black, white stays white
                    .blur(radius: size * 0.02) // second pass softens the hard edges
                    // Color the white metaball shape with a gradient
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color(red: 0.1, green: 0.6, blue: 1.0),  // bright cyan-blue
                                Color(red: 0.2, green: 0.4, blue: 0.9),  // medium blue
                                Color(red: 0.5, green: 0.8, blue: 1.0),  // light cyan
                            ],
                            startPoint: UnitPoint(
                                x: 0.3 + CGFloat(sin(t * 0.5)) * 0.2,
                                y: 0.2 + CGFloat(cos(t * 0.4)) * 0.2
                            ),
                            endPoint: UnitPoint(
                                x: 0.7 + CGFloat(sin(t * 0.3)) * 0.2,
                                y: 0.8 + CGFloat(cos(t * 0.6)) * 0.2
                            )
                        )
                        .blendMode(.sourceAtop)
                    )
                    // Black background must extend under the metaball for contrast trick to work
                    .background(Color.black)
                    .clipShape(Circle())
                    // Semi-transparent so it acts like a glass orb
                    .opacity(0.85)

                    // ── Layer 2: Glass sphere overlays ──

                    // Top-left specular highlight
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.45), .clear],
                                center: .init(x: 0.28, y: 0.25),
                                startRadius: 0,
                                endRadius: size * 0.28
                            )
                        )
                        .blendMode(.screen)

                    // Secondary bottom-right caustic
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.12), .clear],
                                center: .init(x: 0.72, y: 0.75),
                                startRadius: 0,
                                endRadius: size * 0.2
                            )
                        )
                        .blendMode(.screen)

                    // Glossy rim border
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .clear, .white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )

                    // Spherical depth shadow (inner edge darkening)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.clear, .black.opacity(0.6)],
                                center: .center,
                                startRadius: size * 0.32,
                                endRadius: size * 0.5
                            )
                        )
                        .blendMode(.multiply)
                }
                .frame(width: size, height: size)
                // Gentle breathing scale from voice volume
                .scaleEffect(isSpeaking ? 1.0 + min(CGFloat(rms) * 1.5, 0.12) : 0.96)
                .animation(.interpolatingSpring(stiffness: 60, damping: 8), value: rms)
                // Subtle outer glow
                .shadow(
                    color: Color.cyan.opacity(isSpeaking ? 0.15 + min(Double(rms), 0.15) : 0.03),
                    radius: isSpeaking ? 20 : 6
                )
            }
        }
    }
}

/// Parameters for one metaball blob's Lissajous orbit
private struct BlobParams {
    let radius: CGFloat   // fraction of container size
    let xF: Double        // x frequency
    let yF: Double        // y frequency
    let xP: Double        // x phase offset
    let yP: Double        // y phase offset
}

#Preview {
    ContentView(viewModel: BluetoothSpeechViewModel())
}
