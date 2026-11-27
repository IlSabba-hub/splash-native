import Darwin
import Foundation
import Observation

@MainActor @Observable
final class Installer {
    struct Progress: Equatable {
        let repo: String
        let done: Int64
        let total: Int64

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

        init?(line: String) {
            struct Event: Decodable {
                let repo: String
                let done: Int64
                let total: Int64
            }
            guard let event: Event = Installer.event("download", in: line) else { return nil }
            (repo, done, total) = (event.repo, event.done, event.total)
        }
    }

    struct Failure: Decodable, Equatable {
        let kind: String?
        let message: String
        var needed: Int64?
        var available: Int64?

        init?(line: String) {
            guard let failure: Failure = Installer.event("error", in: line) else { return nil }
            self = failure
        }
    }

    enum Outcome: String, Decodable {
        case updated
        case upToDate = "up_to_date"
        case unreachable
        case kept

        init?(line: String) {
            struct Event: Decodable { let outcome: Outcome }
            guard let event: Event = Installer.event("prepared", in: line) else { return nil }
            self = event.outcome
        }
    }

    enum Result: Equatable {
        case checked(Outcome)
        case deleted(freed: Int64)
    }

    nonisolated static func freed(line: String) -> Int64? {
        struct Event: Decodable { let bytes: Int64 }
        let event: Event? = Installer.event("removed", in: line)
        return event?.bytes
    }

    private struct Named: Decodable { let event: String }

    nonisolated private static func event<Event: Decodable>(_ name: String, in line: String) -> Event? {
        let data = Data(line.utf8)
        guard line.hasPrefix("{"), (try? JSONDecoder().decode(Named.self, from: data))?.event == name else { return nil }
        return try? JSONDecoder().decode(Event.self, from: data)
    }

    nonisolated static func words(_ result: Result, name: String) -> (title: String, detail: String, done: Bool) {
        switch result {
        case .checked(.updated): ("\(name) is updated", "Its next start uses the new files.", true)
        case .checked(.upToDate): ("\(name) is up to date", "Hugging Face has nothing newer.", true)
        case .checked(.unreachable): ("Splash couldn’t check \(name) for updates", "Hugging Face was not reachable.", false)
        case .checked(.kept): ("Splash couldn’t update \(name)", "It kept the installed version.", false)
        case .deleted(let freed) where freed > 0: ("Deleted \(name)", "Freed \(Format.size(freed)).", true)
        case .deleted: ("Deleted \(name)", "Its files stayed: other models or tools use them.", true)
        }
    }

    nonisolated static func problem(_ failure: Failure, model: String) -> String {
        let name = model.split(separator: ":")[0]
        switch failure.kind {
        case "disk":
            if let needed = failure.needed, let available = failure.available {
                return "It needs \(Format.size(needed)) of disk space, \(Format.size(needed - available)) more than is free. "
                    + "Free some space, then try again."
            }
            return "The disk is full. Free some space, then try again."
        case "not_found":
            return "Hugging Face has no public model named \(name). Check the name, then try again."
        case "offline":
            return "Splash couldn’t reach Hugging Face. Check the internet connection, then try again."
        case "interrupted":
            return "The connection to Hugging Face dropped during the download. Check the internet connection, then try again."
        case "auth":
            return "Hugging Face refused access to \(name). Sign in with an account that can read it (hf auth login) and, "
                + "if the model asks, accept its terms at huggingface.co/\(name), then try again."
        default:
            return failure.message
        }
    }

    private(set) var model: String?
    private(set) var progress: Progress?
    private(set) var failure: (model: String, message: String)?
    enum Work {
        case download, check, removal

        func phrase(_ name: String, downloading: Bool) -> String {
            switch self {
            case .download: "Downloading \(name)"
            case .check: downloading ? "Downloading \(name)" : "Checking \(name) for updates"
            case .removal: "Deleting \(name)"
            }
        }
    }
    private(set) var work = Work.download
    private(set) var finished: (model: String, result: Result)?

    @ObservationIgnored var installed: (String) -> Void = { _ in }
    @ObservationIgnored var changed: () -> Void = {}

    let log: URL
    private let runtime: Runtime
    private var child: ChildProcess?
    let record: ChildRecord
    private var cancelled = false
    private var reported: Failure?
    private var outcome: Outcome?
    private var freed: Int64?
    private var activity: NSObjectProtocol?
    private var began: (date: Date, done: Int64)?

    init(runtime: Runtime, log: URL, defaults: UserDefaults) {
        self.runtime = runtime
        self.log = log
        record = ChildRecord(defaults: defaults, key: Preference.installerPID, stop: SIGINT, killAfter: .seconds(20))
    }

    var running: Bool { child != nil }

    var remaining: Duration? {
        guard let progress, let began, progress.done > began.done else { return nil }
        let elapsed = Date.now.timeIntervalSince(began.date)
        guard elapsed >= 5 else { return nil }
        return .seconds(Double(progress.total - progress.done) * elapsed / Double(progress.done - began.done))
    }

    func install(_ model: String, _ work: Work = .download, textOnly: Bool = false) {
        run(model, work, textOnly: textOnly)
    }

    func remove(_ model: String, textOnly: Bool = false) {
        run(model, .removal, textOnly: textOnly)
    }

    private func run(_ model: String, _ work: Work, textOnly: Bool) {
        guard child == nil else { return }
        self.model = model
        self.work = work
        progress = nil
        began = nil
        failure = nil
        finished = nil
        reported = nil
        outcome = nil
        freed = nil
        cancelled = false
        resetLog(log)
        do {
            child = try record.start(
                work == .removal
                    ? runtime.removeCommand(model, textOnly: textOnly)
                    : runtime.installCommand(model, textOnly: textOnly),
                environment: runtime.environment,
                log: log,
                line: { [weak self] in self?.received($0) },
                exited: { [weak self] in self?.exited($0) }
            )
        } catch {
            failure = (model, "Splash couldn’t start: \(error.localizedDescription)")
            self.model = nil
            return
        }
        guard work != .removal else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading \(model)")
    }

    func cancel() {
        guard let child else { return }
        cancelled = true
        child.stop(SIGINT, killAfter: .seconds(5))
    }

    func dismissFailure() {
        failure = nil
    }

    func dismissFinished() {
        finished = nil
    }

    func stopLeftover(stopping: () -> Void = {}) async {
        await record.stopLeftover(olderApps: runtime.runsInstaller, stopping: stopping)
    }

    private func received(_ line: String) {
        if let reported = Failure(line: line) {
            self.reported = reported
            return
        }
        if let outcome = Outcome(line: line) {
            self.outcome = outcome
            return
        }
        if let freed = Self.freed(line: line) {
            self.freed = freed
            return
        }
        guard let event = Progress(line: line) else { return }
        guard let model, event.repo == model.split(separator: ":")[0] else { return }
        if began == nil { began = (.now, event.done) }
        progress = event
    }

    private func exited(_ status: Int32) {
        child = nil
        activity.map(ProcessInfo.processInfo.endActivity)
        activity = nil
        guard let model else { return }
        self.model = nil
        progress = nil
        if work == .removal { changed() }
        if status == 0 {
            switch work {
            case .download: installed(model)
            case .check:
                finished = outcome.map { (model, .checked($0)) }
                changed()
            case .removal: finished = freed.map { (model, .deleted(freed: $0)) }
            }
        } else if !cancelled {
            failure = (model, reported.map { Self.problem($0, model: model) }
                ?? "It stopped unexpectedly. The log has the details.")
        }
    }
}
