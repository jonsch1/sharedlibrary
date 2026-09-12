import SwiftUI

struct BrieflyAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            BrieflyBackgroundImage(
                appearance: colorScheme == .dark ? .dark : .light
            )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .accessibilityHidden(true)
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
