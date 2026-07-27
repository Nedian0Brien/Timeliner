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
