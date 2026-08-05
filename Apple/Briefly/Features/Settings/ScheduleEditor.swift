import Foundation
import SwiftUI

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.headline)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }
}
enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct ScheduleEditor: View {
    @Binding var schedule: String

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { schedule != "manual" },
            set: { enabled in
                schedule = enabled
                    ? scheduledValue(frequency: .daily, weekday: weekday, time: time)
                    : "manual"
            }
        )
    }

    private var frequency: ScheduleFrequency {
        schedule.hasPrefix("weekly ") ? .weekly : .daily
    }

    private var frequencyBinding: Binding<ScheduleFrequency> {
        Binding(
            get: { frequency },
            set: { schedule = scheduledValue(frequency: $0, weekday: weekday, time: time) }
        )
    }

    private var weekday: Int {
        guard schedule.hasPrefix("weekly ") else {
            return Calendar.current.component(.weekday, from: Date())
        }
        let code = schedule.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            .firstIndex(of: code).map { $0 + 1 } ?? Calendar.current.firstWeekday
    }

    private var weekdayBinding: Binding<Int> {
        Binding(
            get: { weekday },
            set: { schedule = scheduledValue(frequency: frequency, weekday: $0, time: time) }
        )
    }

    private var time: Date {
        let parts = schedule.split(separator: " ").last?
            .split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 2 else { return Date() }
        return Calendar.current.date(
            bySettingHour: parts[0],
            minute: parts[1],
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { time },
            set: { schedule = scheduledValue(frequency: frequency, weekday: weekday, time: $0) }
        )
    }

    private var orderedWeekdays: [Int] {
        (0..<7).map { (($0 + Calendar.current.firstWeekday - 1) % 7) + 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule automatically")
                        .font(.headline)
                    Text("Leave this off to refresh only when you ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if isEnabled.wrappedValue {
                Picker("Frequency", selection: frequencyBinding) {
                    ForEach(ScheduleFrequency.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                if frequency == .weekly {
                    Picker("Weekday", selection: weekdayBinding) {
                        ForEach(orderedWeekdays, id: \.self) {
                            Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0)
                        }
                    }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scheduledValue(
        frequency: ScheduleFrequency,
        weekday: Int,
        time: Date
    ) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let value = String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
        guard frequency == .weekly else { return "daily \(value)" }
        let code = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][
            min(7, max(1, weekday)) - 1
        ]
        return "weekly \(code) \(value)"
    }
}
