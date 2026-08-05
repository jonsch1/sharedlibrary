import SwiftUI

struct BrieflyAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) {
            context in
            GeometryReader { geometry in
                let time = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 240)
                Color.white.colorEffect(
                    ShaderLibrary.organicAtmosphere(
                        .float2(geometry.size),
                        .float(time),
                        .float(colorScheme == .dark ? 1 : 0)
                    )
                )
            }
        }
        .overlay {
            Rectangle().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.12)
                    : Color.white.opacity(0.08)
            )
        }
    }
}

struct BrieflyLogo: View {
    var body: some View {
        Group {
            #if os(macOS)
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 76, height: 30)
            #else
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 97, height: 39)
            #endif
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefly")
    }
}
