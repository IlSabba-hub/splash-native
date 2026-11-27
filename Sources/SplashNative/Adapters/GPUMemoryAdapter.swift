import NativeCore
import NativeUI
import Foundation
import Observation

@MainActor
@Observable
final class GPUMemoryController {
    struct Reading: Equatable {
        var active: UInt64?
        var metal: UInt64?
        var physical: UInt64?
        var daemon: GPUWiredLimit.DaemonState
    }

    typealias Runner = @Sendable (_ arguments: [String]) async -> Command.Result?

    private(set) var reading: Reading
    var selection: Double?
    private(set) var pending: GPUWiredLimit.PrivilegedCommand?
    private(set) var running: GPUWiredLimit.PrivilegedCommand?
    private(set) var outcome: GPUMemoryOutcome?
    private(set) var lastPlacement: GPUMemoryConfirmation.Placement?
    private let read: @MainActor () -> Reading
    private let run: Runner
    private let didRead: @MainActor (Reading) -> Void

    init(read: @escaping @MainActor () -> Reading = GPUMemoryController.readSystem, run: @escaping Runner = GPUMemoryController.runOsascript,
         didRead: @escaping @MainActor (Reading) -> Void = { _ in }) {
        self.read = read
        self.run = run
        self.didRead = didRead
        reading = read()
        selectRestingIfNeeded()
    }

    static func readSystem() -> Reading {
        Reading(active: GPUWiredLimit.readActive(), metal: MemoryGuard.metalBudget(), physical: SystemMemory.read().physicalBytes,
                daemon: GPUWiredLimit.readDaemon())
    }

    static let runOsascript: Runner = { arguments in
        try? await Command.run(arguments, timeout: .seconds(600))
    }

    func refresh() {
        reading = read()
        selectRestingIfNeeded()
        didRead(reading)
    }

    var limits: GPUWiredLimit.Limits? { reading.physical.map(GPUWiredLimit.Limits.init(physicalBytes:)) }

    var currentMiB: UInt64? {
        guard let active = reading.active else { return nil }
        return active > 0 ? active : reading.metal.map { $0 >> 20 }
    }

    var selectedMiB: UInt64? {
        guard let selection, selection > 0, let limits else { return nil }
        return limits.validated(UInt64(selection) >> 20)
    }

    private func restingBytes(_ limits: GPUWiredLimit.Limits) -> Double {
        let mib = min(max(currentMiB ?? limits.highestMiB, limits.lowestMiB), limits.highestMiB)
        return Double(mib << 20)
    }

    private func selectRestingIfNeeded() {
        guard selection == nil, let limits, limits.allowsChoice else { return }
        selection = restingBytes(limits)
    }

    func ask(_ command: GPUWiredLimit.PrivilegedCommand) {
        pending = command
        outcome = nil
        lastPlacement = Self.placement(command.kind)
    }

    func cancel() {
        pending = nil
    }

    func confirm() async {
        guard let command = pending, running == nil else { return }
        pending = nil
        running = command
        let result = await run(GPUWiredLimit.osascriptArguments(command, prompt: Self.prompt(command.kind)))
        running = nil
        refresh()
        outcome = Self.outcome(of: command.kind, result: result, reading: reading)
    }

    static func placement(_ kind: GPUWiredLimit.PrivilegedCommand.Kind) -> GPUMemoryConfirmation.Placement {
        switch kind {
        case .apply, .reset: .apply
        case .install, .remove: .daemon
        }
    }

    static func prompt(_ kind: GPUWiredLimit.PrivilegedCommand.Kind) -> String {
        switch kind {
        case let .apply(mib): tr("gpu.prompt.apply", NativeFormat.count(Int(mib)))
        case .reset: tr("gpu.prompt.reset")
        case let .install(mib): tr("gpu.prompt.install", NativeFormat.count(Int(mib)))
        case .remove: tr("gpu.prompt.remove")
        }
    }

    static func outcome(of kind: GPUWiredLimit.PrivilegedCommand.Kind, result: Command.Result?, reading: Reading) -> GPUMemoryOutcome {
        guard let result else {
            let reason = tr("gpu.failed.noResult")
            return GPUMemoryOutcome(text: tr("gpu.failed", reason), isError: true)
        }
        if result.status != 0 {
            if GPUWiredLimit.wasCancelled(result.errorText) { return GPUMemoryOutcome(text: tr("gpu.cancelled"), isError: false) }
            let written = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = tr("gpu.failed.status", String(result.status))
            return GPUMemoryOutcome(text: tr("gpu.failed", written.isEmpty ? status : written), isError: true)
        }
        switch kind {
        case let .apply(mib):
            return reading.active == mib ? GPUMemoryOutcome(text: tr("gpu.done.active", activeText(reading.active)), isError: false)
                : GPUMemoryOutcome(text: tr("gpu.mismatch", activeText(reading.active)), isError: true)
        case .reset:
            return reading.active == 0 ? GPUMemoryOutcome(text: tr("gpu.done.active", activeText(reading.active)), isError: false)
                : GPUMemoryOutcome(text: tr("gpu.mismatch", activeText(reading.active)), isError: true)
        case let .install(mib):
            return reading.daemon == .installed(mib: mib)
                ? GPUMemoryOutcome(text: tr("gpu.done.install", NativeFormat.count(Int(mib))), isError: false)
                : GPUMemoryOutcome(text: tr("gpu.mismatch", daemonText(reading.daemon)), isError: true)
        case .remove:
            return reading.daemon == .absent ? GPUMemoryOutcome(text: tr("gpu.done.remove"), isError: false)
                : GPUMemoryOutcome(text: tr("gpu.mismatch", daemonText(reading.daemon)), isError: true)
        }
    }

    static func activeText(_ active: UInt64?) -> String {
        guard let active else { return tr("value.unavailable") }
        return active == 0 ? tr("gpu.active.default") : tr("gpu.mbMemory", NativeFormat.count(Int(active)), NativeFormat.memory(Int64(active << 20)))
    }

    static func daemonText(_ state: GPUWiredLimit.DaemonState) -> String {
        switch state {
        case .absent: tr("gpu.daemon.absent")
        case let .installed(mib): tr("gpu.daemon.installed", NativeFormat.count(Int(mib)))
        case .unreadable: tr("gpu.daemon.unreadable")
        case .unexpected: tr("gpu.daemon.unexpected")
        }
    }

    private static func bytes(_ value: UInt64?, reason: String) -> Measured<String> {
        value.map { .value(NativeFormat.memory(Int64(clamping: $0))) } ?? .unavailable(reason: reason)
    }

    var presentation: GPUMemoryPresentation {
        let reading = reading, limits = limits
        let busy = pending != nil || running != nil
        let system = { (name: String) in Provenance(source: .system(name: name)) }
        let rule = Provenance(flag: "--max-memory", source: .file(name: "runtime/engine/MemoryPlan.hpp · EngineMemoryPolicy (Splash 1.7.3)"))

        let automatic: UInt64? = reading.metal.flatMap { metal in
            reading.physical.map { GPUWiredLimit.SplashBudget.automatic(recommended: metal, physical: $0) }
        }
        let now = [
            SettingsRow(id: "gpu.active", title: tr("gpu.active"),
                        value: reading.active.map { .value(Self.activeText($0)) } ?? .unavailable(reason: tr("gpu.reason.sysctl")),
                        provenance: system("sysctl iogpu.wired_limit_mb")),
            SettingsRow(id: "gpu.metal", title: tr("gpu.metal"), value: Self.bytes(reading.metal, reason: tr("gpu.reason.metal")),
                        provenance: system("MTLDevice.recommendedMaxWorkingSetSize")),
            SettingsRow(id: "gpu.splashAuto", title: tr("gpu.splashAuto"), value: Self.bytes(automatic, reason: tr("gpu.reason.inputs")),
                        provenance: rule),
            SettingsRow(id: "gpu.memory", title: tr("gpu.memory"), value: Self.bytes(reading.physical, reason: tr("gpu.reason.memsize")),
                        provenance: system("sysctl hw.memsize")),
        ]

        var slider: SectionState<GPUMemorySlider>
        var effect: [SettingsRow] = []
        var apply: NativeAction?
        var install: NativeAction?
        if let limits, limits.allowsChoice {
            let resting = restingBytes(limits)
            var notes: [String] = []
            if let mib = selectedMiB {
                notes.append(tr("gpu.slider.exact", String(mib)))
                if reading.active == 0, let metal = reading.metal, mib << 20 < metal { notes.append(tr("gpu.slider.belowDefault")) }
                let recommended = GPUWiredLimit.SplashBudget.recommendation(limitMiB: mib)
                effect = [
                    SettingsRow(id: "gpu.effect.metal", title: tr("gpu.effect.metal"), value: .value(NativeFormat.memory(Int64(recommended))),
                                provenance: rule),
                    SettingsRow(id: "gpu.effect.auto", title: tr("gpu.effect.auto"),
                                value: .value(NativeFormat.memory(Int64(GPUWiredLimit.SplashBudget.automatic(recommended: recommended,
                                                                                                        physical: limits.physicalBytes)))),
                                provenance: rule),
                    SettingsRow(id: "gpu.effect.explicit", title: tr("gpu.effect.explicit"),
                                value: .value(NativeFormat.memory(Int64(GPUWiredLimit.SplashBudget.explicitCeiling(recommended: recommended)))),
                                provenance: rule),
                    SettingsRow(id: "gpu.effect.left", title: tr("gpu.effect.left"),
                                value: .value(NativeFormat.memory(Int64(limits.physicalBytes - recommended))), provenance: system("sysctl hw.memsize")),
                ]
            }
            slider = .available(GPUMemorySlider(lowestBytes: Double(limits.lowestMiB << 20), highestBytes: Double(limits.highestMiB << 20),
                                                restingBytes: resting, current: Self.activeText(reading.active), notes: notes))
            let mib = selectedMiB
            let applyReason: String? = if busy { tr("gpu.disabled.busy") }
                else if reading.active == nil { tr("gpu.disabled.unknown") }
                else if mib == nil { tr("gpu.disabled.outside") }
                else if mib == currentMiB { tr("gpu.disabled.same") }
                else { nil }
            let applyCommand = mib.flatMap { GPUWiredLimit.apply($0, limits: limits) }
            apply = NativeAction(title: tr("gpu.action.apply"), systemImage: "bolt", role: .primary, isEnabled: applyReason == nil,
                               disabledReason: applyReason) { [weak self] in if let applyCommand { self?.ask(applyCommand) } }
            let installReason: String? = if busy { tr("gpu.disabled.busy") }
                else if mib == nil { tr("gpu.disabled.outside") }
                else if case let .installed(installed) = reading.daemon, installed == mib { tr("gpu.disabled.sameDaemon") }
                else { nil }
            let installCommand = mib.flatMap { GPUWiredLimit.install($0, limits: limits) }
            install = NativeAction(title: tr("gpu.action.install"), systemImage: "arrow.clockwise.circle", isEnabled: installReason == nil,
                                 disabledReason: installReason) { [weak self] in if let installCommand { self?.ask(installCommand) } }
        } else if let limits {
            slider = .unavailable(reason: tr("gpu.noChoice", NativeFormat.memory(Int64(limits.reserveBytes))))
        } else {
            slider = .unavailable(reason: tr("gpu.reason.memsize"))
        }

        let resetReason: String? = if busy { tr("gpu.disabled.busy") }
            else if reading.active == nil { tr("gpu.disabled.unknown") }
            else if reading.active == 0 { tr("gpu.disabled.isDefault") }
            else { nil }
        let reset = NativeAction(title: tr("gpu.action.reset"), systemImage: "arrow.uturn.backward", isEnabled: resetReason == nil,
                               disabledReason: resetReason) { [weak self] in self?.ask(GPUWiredLimit.reset) }
        let remove: NativeAction? = reading.daemon == .absent ? nil
            : NativeAction(title: tr("gpu.action.remove"), systemImage: "trash", isEnabled: !busy,
                         disabledReason: busy ? tr("gpu.disabled.busy") : nil) { [weak self] in self?.ask(GPUWiredLimit.remove()) }

        let daemonValue: Measured<String> = switch reading.daemon {
        case .unreadable: .unavailable(reason: tr("gpu.daemon.unreadable"))
        default: .value(Self.daemonText(reading.daemon))
        }
        let daemon = [SettingsRow(id: "gpu.daemon", title: tr("gpu.daemon.state"), value: daemonValue, detail: GPUWiredLimit.daemonPath,
                                  provenance: Provenance(source: .file(name: GPUWiredLimit.daemonPath)))]

        let confirmation = pending.map { command in
            GPUMemoryConfirmation(placement: Self.placement(command.kind), question: Self.question(command.kind), command: command.shell,
                                  filePath: command.writes?.path,
                                  confirm: NativeAction(title: tr("gpu.confirm.run"), role: .primary) { [weak self] in
                                      Task { await self?.confirm() }
                                  },
                                  cancel: NativeAction(title: tr("confirm.cancel")) { [weak self] in self?.cancel() })
        }
        return GPUMemoryPresentation(now: now, slider: slider, effect: effect,
                                     reserve: limits.map { NativeFormat.memory(Int64($0.reserveBytes)) },
                                     apply: apply, reset: reset, daemon: daemon, install: install, remove: remove,
                                     confirmation: confirmation, progress: running.map { _ in tr("gpu.running") }, outcome: outcome,
                                     lastPlacement: lastPlacement)
    }

    static func question(_ kind: GPUWiredLimit.PrivilegedCommand.Kind) -> String {
        switch kind {
        case let .apply(mib): tr("gpu.confirm.apply", NativeFormat.count(Int(mib)))
        case .reset: tr("gpu.confirm.reset")
        case let .install(mib): tr("gpu.confirm.install", NativeFormat.count(Int(mib)))
        case .remove: tr("gpu.confirm.remove")
        }
    }
}
