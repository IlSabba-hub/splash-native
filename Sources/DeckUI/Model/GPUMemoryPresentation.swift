import Foundation

public struct GPUMemoryPresentation: Sendable {
    public let now: [SettingsRow]
    public let slider: SectionState<GPUMemorySlider>
    public let effect: [SettingsRow]
    public let reserve: String?
    public let apply: DeckAction?
    public let reset: DeckAction?
    public let daemon: [SettingsRow]
    public let install: DeckAction?
    public let remove: DeckAction?
    public let confirmation: GPUMemoryConfirmation?
    public let progress: String?
    public let outcome: GPUMemoryOutcome?
    public let lastPlacement: GPUMemoryConfirmation.Placement?

    public init(now: [SettingsRow], slider: SectionState<GPUMemorySlider>, effect: [SettingsRow], reserve: String?,
                apply: DeckAction?, reset: DeckAction?, daemon: [SettingsRow], install: DeckAction?, remove: DeckAction?,
                confirmation: GPUMemoryConfirmation?, progress: String?, outcome: GPUMemoryOutcome?,
                lastPlacement: GPUMemoryConfirmation.Placement?) {
        self.now = now
        self.slider = slider
        self.effect = effect
        self.reserve = reserve
        self.apply = apply
        self.reset = reset
        self.daemon = daemon
        self.install = install
        self.remove = remove
        self.confirmation = confirmation
        self.progress = progress
        self.outcome = outcome
        self.lastPlacement = lastPlacement
    }
}

public struct GPUMemorySlider: Sendable, Equatable {
    public let lowestBytes: Double
    public let highestBytes: Double
    public let restingBytes: Double
    public let current: String
    public let notes: [String]

    public init(lowestBytes: Double, highestBytes: Double, restingBytes: Double, current: String, notes: [String]) {
        self.lowestBytes = lowestBytes
        self.highestBytes = highestBytes
        self.restingBytes = restingBytes
        self.current = current
        self.notes = notes
    }
}

public struct GPUMemoryConfirmation: Sendable {
    public enum Placement: Sendable { case apply, daemon }

    public let placement: Placement
    public let question: String
    public let command: String
    public let filePath: String?
    public let confirm: DeckAction
    public let cancel: DeckAction

    public init(placement: Placement, question: String, command: String, filePath: String?, confirm: DeckAction, cancel: DeckAction) {
        self.placement = placement
        self.question = question
        self.command = command
        self.filePath = filePath
        self.confirm = confirm
        self.cancel = cancel
    }
}

public struct GPUMemoryOutcome: Sendable, Equatable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}
