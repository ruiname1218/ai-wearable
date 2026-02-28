import SwiftUI

@main
struct XiaoVoiceBridgeApp: App {
    @StateObject private var viewModel = BluetoothSpeechViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.requestSpeechAuthorization()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.setAppIsInBackground(false)
            case .inactive, .background:
                viewModel.setAppIsInBackground(true)
            @unknown default:
                viewModel.setAppIsInBackground(false)
            }
        }
    }
}
