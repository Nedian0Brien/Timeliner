import Foundation
import SwiftData
import SwiftUI

/// Which body of data the app is looking at.
///
/// A development affordance: the sample set is what the design work is done against,
/// and the real set is what the app would hold in someone's hands. Keeping both around
/// means neither has to be faked or cleared to see the other.
enum DataMode: String, CaseIterable, Identifiable {
    case sample
    case real

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sample: return "더미 데이터"
        case .real: return "실제 데이터"
        }
    }

    var detail: String {
        switch self {
        case .sample: return "디자인용 샘플이 채워진 저장소입니다. 여기서 무엇을 지우든 실제 데이터에는 닿지 않습니다."
        case .real: return "샘플이 한 번도 들어간 적 없는 저장소입니다. 처음에는 비어 있습니다."
        }
    }

    /// One store file per mode, rather than a flag on every model.
    ///
    /// Nothing that reads data has to know the mode exists: no `@Query` gains a
    /// predicate, and no sample row can leak into real data by way of a filter someone
    /// forgot to add. The cost is that the two sets cannot see each other, which is
    /// exactly what is wanted here.
    var storeURL: URL? {
        switch self {
        // Left at SwiftData's default location, because that is the store every build
        // before this one wrote to — the seeded data is already there.
        case .sample: return nil
        case .real:
            return URL.applicationSupportDirectory.appending(path: "TimelinerReal.store")
        }
    }
}

/// Owns the container, and swaps it when the mode changes.
@MainActor
final class DataStore: ObservableObject {
    @Published private(set) var mode: DataMode
    @Published private(set) var container: ModelContainer
    @Published private(set) var warning: String?

    private static let modeKey = "dataMode"

    /// Every container this session has opened, kept alive for as long as the app runs.
    ///
    /// Not a cache for speed. Swapping the container tears the view tree down, but not
    /// instantly: rows from the outgoing store are still on screen for the frames it
    /// takes SwiftUI to notice, and a model object outlives its container only as far as
    /// the next property read — after that SwiftData traps. Holding the old container
    /// keeps those objects legible until nothing is looking at them any more.
    private var containers: [DataMode: ModelContainer] = [:]

    private static let schema = Schema([
        Schedule.self,
        Record.self,
        RecordPhoto.self,
        TodoItem.self
    ])

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.modeKey)
        let initial = stored.flatMap(DataMode.init(rawValue:)) ?? .sample
        let loaded = Self.load(initial)
        mode = initial
        container = loaded.container
        warning = loaded.warning
        containers[initial] = loaded.container
    }

    func select(_ newMode: DataMode) {
        guard newMode != mode else { return }
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)

        if let existing = containers[newMode] {
            mode = newMode
            container = existing
            warning = nil
            return
        }

        let loaded = Self.load(newMode)
        containers[newMode] = loaded.container
        mode = newMode
        container = loaded.container
        warning = loaded.warning
    }

    private static func load(_ mode: DataMode) -> (container: ModelContainer, warning: String?) {
        let config: ModelConfiguration
        if let url = mode.storeURL {
            config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }

        do {
            return (try ModelContainer(for: schema, configurations: [config]), nil)
        } catch {
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let warning = "로컬 저장소를 열지 못해 임시 저장소로 실행 중입니다. 앱을 종료하면 이번 실행의 변경 사항은 유지되지 않습니다."
                return (try ModelContainer(for: schema, configurations: [memoryConfig]), warning)
            } catch {
                fatalError("SwiftData container creation failed: \(error.localizedDescription)")
            }
        }
    }
}
