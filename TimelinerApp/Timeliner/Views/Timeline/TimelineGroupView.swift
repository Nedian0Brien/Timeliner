import Foundation

struct GroupedDay: Identifiable {
    let id: Date
    let date: Date
    var schedules: [Schedule]
    var todos: [TodoItem]
    var records: [Record]
}
