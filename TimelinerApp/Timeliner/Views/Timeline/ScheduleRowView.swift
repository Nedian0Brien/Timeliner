import SwiftUI

struct ScheduleRowView: View {
    @Environment(\.colorScheme) private var scheme
    let schedule: Schedule
    let onTap: () -> Void

    var body: some View {
        let pill = PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark)
        Button(action: onTap) {
            HStack(spacing: 12) {
                Capsule()
                    .fill(pill.tint)
                    .frame(width: 5, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.text)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(schedule.calendarName ?? "일정")
                            .foregroundStyle(pill.tint)
                        if let location = schedule.locationText, !location.isEmpty {
                            Text("·")
                            Text(location).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(schedule.timeString.map(DateHelpers.format24Hour) ?? "종일")
                        .font(.caption.bold())
                    if let end = schedule.endTimeString {
                        Text(DateHelpers.format24Hour(from: end))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(pill.surface, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(pill.tint.opacity(0.25), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }
}
