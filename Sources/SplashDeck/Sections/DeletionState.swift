import DeckCore
import DeckUI
import Foundation
import Observation

@MainActor @Observable
final class DeletionState: Identifiable {
    let id: String
    let shelf: ModelShelf
    private(set) var choices = DeletionChoices()
    private(set) var plan: DeletionPlan?
    private(set) var checking = false
    private(set) var running = false
    private(set) var outcome: DeletionOutcome?
    private(set) var gone = false
    @ObservationIgnored var confirm: @Sendable (String) async -> OwnerAuthentication.Outcome = { reason in
        await OwnerAuthentication.confirm(reason: reason)
    }

    @ObservationIgnored var trash: any Trash = SystemTrash()

    init(id: String, shelf: ModelShelf) {
        self.id = id
        self.shelf = shelf
    }

    func check() async {
        checking = true
        defer { checking = false }
        plan = await shelf.deletionPlan(for: id, choices: choices)
        gone = plan == nil
    }

    func choose(_ change: (inout DeletionChoices) -> Void) {
        change(&choices)
        Task { await check() }
    }

    func run() async {
        guard let plan, plan.canProceed, !running else { return }
        running = true
        defer { running = false }
        let reason = tr("delete.reason", plan.model.name)
        let confirm = confirm
        outcome = await shelf.delete(plan, trash: trash) { await confirm(reason) }
        if outcome?.moved.isEmpty == true, outcome?.removals.isEmpty == true { await check() }
    }
}
