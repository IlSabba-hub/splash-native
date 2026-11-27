import DeckCore
import DeckUI
import Foundation
import Observation

@MainActor @Observable
final class AppServices {
    static let shared = AppServices()

    var model: DeckModel { ServerBoard.shared.model }
    let sampler = ResourceSampler { target, time in
        if let sample = await ServerBoard.shared.live.sample(target) { return sample }
        return await ResourceSampler.fetch(target, at: time)
    }
    let stats = StatsRecorder()
    let navigation = DeckNavigation(section: UserDefaults.standard.string(forKey: "deckInitialSection").flatMap(DeckSection.init(rawValue:)) ?? .chat)
    let library = LibraryState(deck: ServerBoard.shared.model)
    let versions = VersionsController()
    var processesScanned: Bool { ServerBoard.shared.prepared }

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    private init() {}

    func start() {
        guard tasks.isEmpty else { return }
        let sampler = sampler, stats = stats
        tasks.append(Task {
            await stats.attach(to: sampler)
            await sampler.run { ServerBoard.shared.model.sampleTargets }
        })
        tasks.append(Task {
            while !ServerBoard.shared.prepared { try? await Task.sleep(for: .milliseconds(500)) }
            self.versions.refreshUpdateBadge(navigation: self.navigation, model: self.model)
            if self.library.shelf.scanned == nil { await self.library.load() }
        })
        tasks.append(Task { await self.calibrateMemoryWhenIdle() })
    }

    private func calibrateMemoryWhenIdle() async {
        while !ServerBoard.shared.prepared { try? await Task.sleep(for: .milliseconds(500)) }
        var tried: Set<String> = []
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard UserDefaults.standard.bool(forKey: DeckPreferences.memoryAutoProbe) else { continue }
            let model = self.model
            guard model.memoryProbe == nil, model.supervisor.alive.isEmpty, model.found.isEmpty else { continue }
            guard let next = model.uncalibratedConfigurations.first(where: { !tried.contains(model.memoryFingerprint($0) ?? $0.name) })
            else { continue }
            tried.insert(model.memoryFingerprint(next) ?? next.name)
            _ = try? await model.measureMemory(next)
        }
    }
}
