import Foundation
import SwiftData

@Model
final class Record {
    @Attribute(.unique) var id: UUID = UUID()
    /// Which day this belongs to, as a start of day. The timeline groups by it.
    ///
    /// Seeded records used to put a whole moment here while the composer put a start of
    /// day, and both worked only because every reader ran it back through `startOfDay`.
    /// It means one thing now.
    var date: Date = Date()
    /// The moment being recorded, which is not the same as `createdAt` — a note written
    /// in the evening can be about the morning.
    ///
    /// This replaced a `"09:30 AM"` string. See `Schedule.startAt` for what that string
    /// could not do.
    var occurredAt: Date = Date()
    var text: String = ""
    @Relationship(deleteRule: .cascade, inverse: \RecordPhoto.record)
    var photos: [RecordPhoto] = []
    var createdAt: Date = Date()

    /// Takes the moment and derives the day from it, so the two can never disagree.
    init(
        id: UUID = UUID(),
        occurredAt: Date,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = DateHelpers.startOfDay(occurredAt)
        self.occurredAt = occurredAt
        self.text = text
        self.createdAt = createdAt
    }

    /// Minutes past midnight, for ordering rows inside one day.
    var minutes: Int { DateHelpers.minutesSinceMidnight(from: occurredAt) }

    /// "09:30".
    var timeText: String { DateHelpers.format24Hour(from: occurredAt) }

    /// Relationships come back unordered, so the sort is not optional dressing — without
    /// it a record's photos would shuffle between launches.
    var orderedPhotos: [RecordPhoto] {
        photos.sorted { $0.sortOrder < $1.sortOrder }
    }
}

extension Record: Identifiable {}

/// One photo attached to a record.
///
/// Its own entity rather than a `[Data]` on `Record`: SwiftData stores an array as a
/// single encoded value, which puts `.externalStorage` out of reach and drags every
/// attached photo along on any fetch of the record. The timeline fetches a great many
/// records, so the blobs have to stay outside the row.
@Model
final class RecordPhoto {
    @Attribute(.unique) var id: UUID = UUID()
    @Attribute(.externalStorage) var data: Data = Data()
    var sortOrder: Int = 0
    var record: Record?

    init(id: UUID = UUID(), data: Data, sortOrder: Int) {
        self.id = id
        self.data = data
        self.sortOrder = sortOrder
    }
}

extension RecordPhoto: Identifiable {}
