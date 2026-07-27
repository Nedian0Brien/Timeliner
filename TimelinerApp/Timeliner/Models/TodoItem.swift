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

    init(
        id: UUID = UUID(),
        date: Date,
        text: String,
        completed: Bool = false,
        sortOrder: Int = 0,
        reminderIdentifier: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.completed = completed
        self.sortOrder = sortOrder
        self.reminderIdentifier = reminderIdentifier
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

extension TodoItem: Identifiable {}
