import SwiftUI

@main
struct AFUScaleApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var scale = ScaleController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scale)
                .onAppear {
                    // 已选快捷指令写入就不再骚扰健康授权。
                    if !scale.captureMode && !scale.usesShortcut {
                        scale.requestHealthAuthorization()
                    }
                }
                .onChange(of: phase) { _, newValue in scale.lifecycle(String(describing: newValue)) }
                .onOpenURL { scale.handleCallback($0) }
        }
    }
}
