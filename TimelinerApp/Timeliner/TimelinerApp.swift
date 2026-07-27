import SwiftUI
import SwiftData

@main
struct TimelinerApp: App {
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var dataStore = DataStore()
    @State private var dismissedWarning = false

    init() {
        // Sized here rather than left at the default few megabytes: a chosen background
        // should survive a relaunch and a flight, and `AsyncImage` reads through this.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appearance)
                .environmentObject(dataStore)
                // No `.id(dataStore.mode)` here, deliberately. Re-keying the tree does
                // force every query to start over, but it also throws away the screen
                // the switch was made on — the settings tab would vanish under the
                // finger that tapped it. The queries re-fetch on the context change by
                // themselves; `DataStore` keeps the outgoing container alive so the rows
                // still on screen stay readable while that happens.
                .overlay(alignment: .top) {
                    if let warning = dataStore.warning, !dismissedWarning {
                        storageWarningBanner(warning)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                }
                .modelContainer(dataStore.container)
        }
    }

    private func storageWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                dismissedWarning = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
