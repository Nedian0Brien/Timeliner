import Foundation
import SwiftData

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID = UUID()
    var date: Date = Date()
    var text: String = ""
    var completed: Bool = false
    var sortOrder: Int = 0
    var reminderIdentifier: String? = nil
    var createdAt: Date = Date()
    /// When this item was ticked off. Cleared again if it is un-ticked. The timeline
    /// reads it to move a finished block from when it was written down to when the work
    /// actually ended.
    var completedAt: Date? = nil
    /// When to raise a notification for this item, or `nil` for none.
    ///
    /// A whole moment rather than a time of day, even though `date` only ever holds a
    /// start of day. Notifications are scheduled against an absolute instant, and keeping
    /// the day here too means the two can never disagree about which day is meant — the
    /// edit sheet moves this along whenever `date` moves.
    var reminderAt: Date? = nil

    init(
        id: UUID = UUID(),
        date: Date,
        text: String,
        completed: Bool = false,
        sortOrder: Int = 0,
        reminderIdentifier: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        reminderAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.completed = completed
        self.sortOrder = sortOrder
        self.reminderIdentifier = reminderIdentifier
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.reminderAt = reminderAt
    }
}

extension TodoItem: Identifiable {}

/// Working out what `sortOrder` should become after a drag.
///
/// Pulled out of the views because two of them reorder now — the todo list and the
/// timeline's todo block — and because the interesting case is not reachable from either
/// without setting up a store: a day whose visible rows are only part of it.
enum TodoOrdering {
    /// - Parameters:
    ///   - daySlots: every todo of that day, in the order they currently sit.
    ///   - visibleInNewOrder: the rows that were on screen, in the order the drag left
    ///     them. A subsequence of `daySlots`.
    /// - Returns: the new `sortOrder` for each id that moves.
    ///
    /// Slots are what get preserved, not positions in the visible list. A slot held by a
    /// row nobody could see keeps it, and the visible rows are dealt back into the slots
    /// they already occupied, in their new order. Renumbering the visible rows 0…n
    /// instead would quietly shuffle the hidden ones — you would turn the filter back on
    /// and find a different list than you left.
    static func renumber(daySlots: [UUID], visibleInNewOrder: [UUID]) -> [UUID: Int] {
        // Anything that is not part of the day is dropped before it can take a slot.
        // Letting one through would push the last real row off the end of the run, and
        // that row would then keep its old number while another took its slot — two rows
        // holding one order, which sorts arbitrarily.
        let ownIDs = Set(daySlots)
        let incomingIDs = visibleInNewOrder.filter(ownIDs.contains)
        let visible = Set(incomingIDs)
        var incoming = incomingIDs.makeIterator()
        var result: [UUID: Int] = [:]

        for (slot, occupant) in daySlots.enumerated() {
            if visible.contains(occupant) {
                guard let next = incoming.next() else { continue }
                result[next] = slot
            } else {
                result[occupant] = slot
            }
        }
        return result
    }
}
