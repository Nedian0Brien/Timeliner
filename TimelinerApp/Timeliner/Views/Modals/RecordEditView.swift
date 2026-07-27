import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// A photo on the sheet, whether it is already stored or was just picked.
///
/// `existing` is what makes the save a diff rather than a rewrite: without it the only
/// way to persist an edit would be to delete every row and write them all back, which
/// churns the external-storage files for photos that never changed.
private struct EditPhoto: Identifiable {
    let id: UUID
    let data: Data
    let existing: RecordPhoto?
}

struct RecordEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var record: Record
    @State private var draft: String = ""
    @State private var draftPhotos: [EditPhoto] = []
    /// Transient: the picker here means "add these", so it is emptied once they land.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(DateHelpers.koreanDateLabel(record.date), systemImage: "calendar")
                    Text("·")
                    Label(record.timeString, systemImage: "clock")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                photoEditor
                    .padding(.horizontal, 16)

                TextEditor(text: $draft)
                    .font(.body)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassCard(cornerRadius: 20)
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
            .navigationTitle("기록 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                        .fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftPhotos.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive, action: deleteRecord) {
                        Label("삭제", systemImage: "trash")
                    }
                }
            }
            .onAppear {
                draft = record.text
                draftPhotos = record.orderedPhotos.map {
                    EditPhoto(id: $0.id, data: $0.data, existing: $0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
            }
            .alert("저장 실패", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var photoEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draftPhotos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(draftPhotos) { photo in
                            ZStack(alignment: .topTrailing) {
                                RecordPhotoView(photoID: photo.id, photoData: photo.data)
                                    .frame(width: 96, height: 96)
                                    .clipShape(.rect(cornerRadius: 14))

                                Button {
                                    draftPhotos.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(.black.opacity(0.55)))
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .accessibilityLabel("사진 제거")
                            }
                            // Drag begins on a long press, so a plain swipe still scrolls
                            // the strip rather than picking a thumbnail up.
                            .draggable(photo.id.uuidString) {
                                RecordPhotoView(photoID: photo.id, photoData: photo.data)
                                    .frame(width: 72, height: 72)
                                    .clipShape(.rect(cornerRadius: 12))
                            }
                            .dropDestination(for: String.self) { items, _ in
                                move(items.first, onto: photo.id)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                .frame(height: 98)
            }

            HStack(spacing: 8) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: remainingPhotoSlots,
                    selectionBehavior: .ordered,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Label(draftPhotos.isEmpty ? "사진 추가" : "사진 더 추가", systemImage: "photo")
                }
                .buttonStyle(.glass)
                .disabled(remainingPhotoSlots == 0)
                .onChange(of: pickerItems) { _, items in
                    appendPicked(items)
                }

                if !draftPhotos.isEmpty {
                    Text("\(draftPhotos.count)/\(RecordInputDraft.maxPhotoCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var remainingPhotoSlots: Int {
        max(0, RecordInputDraft.maxPhotoCount - draftPhotos.count)
    }

    /// Takes the dragged photo out and puts it back where the target sits.
    ///
    /// The order in `draftPhotos` is the order that gets written: `applyPhotoEdits`
    /// renumbers `sortOrder` from the array on save, so nothing else has to be told
    /// about the move.
    private func move(_ draggedID: String?, onto targetID: UUID) {
        guard let draggedID, let dragged = UUID(uuidString: draggedID), dragged != targetID,
              let from = draftPhotos.firstIndex(where: { $0.id == dragged }),
              let to = draftPhotos.firstIndex(where: { $0.id == targetID })
        else { return }

        withAnimation(.snappy(duration: 0.22)) {
            let photo = draftPhotos.remove(at: from)
            draftPhotos.insert(photo, at: to)
        }
    }

    /// Appends rather than replaces, and clears the selection afterwards, so the picker
    /// reads as "add more" every time it is opened instead of as the current set.
    private func appendPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard draftPhotos.count < RecordInputDraft.maxPhotoCount else { break }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    draftPhotos.append(EditPhoto(id: UUID(), data: data, existing: nil))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            pickerItems = []
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        record.text = trimmed.isEmpty ? "사진" : trimmed
        applyPhotoEdits()

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    /// A diff against what is stored: rows the sheet no longer lists are deleted, the
    /// ones it still lists are renumbered into their new order, and anything picked
    /// during this sitting is inserted.
    private func applyPhotoEdits() {
        let kept = Set(draftPhotos.compactMap { $0.existing?.id })
        for photo in record.photos where !kept.contains(photo.id) {
            modelContext.delete(photo)
        }

        for (index, photo) in draftPhotos.enumerated() {
            if let existing = photo.existing {
                existing.sortOrder = index
            } else {
                let attachment = RecordPhoto(data: photo.data, sortOrder: index)
                attachment.record = record
                modelContext.insert(attachment)
            }
        }
    }

    private func deleteRecord() {
        modelContext.delete(record)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
