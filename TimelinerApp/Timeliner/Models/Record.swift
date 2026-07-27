import Foundation
import SwiftData

@Model
final class Record {
    @Attribute(.unique) var id: UUID = UUID()
    var date: Date = Date()
    var timeString: String = ""
    var text: String = ""
    @Relationship(deleteRule: .cascade, inverse: \RecordPhoto.record)
    var photos: [RecordPhoto] = []
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        date: Date,
        timeString: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.timeString = timeString
        self.text = text
        self.createdAt = createdAt
    }

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
