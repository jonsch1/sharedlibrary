import SwiftUI

struct BrieflyOnboarding: View {
    static let completionKey = "BrieflyOnboardingVersion"
    static let currentVersion = 1

    let complete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.welcome
    @State private var depth = OnboardingDepth.concise
    @State private var movesForward = true

    var body: some View {
        ZStack {
            BrieflyAtmosphere()
                .ignoresSafeArea()

            #if os(macOS)
            macLayout
            #else
            mobileLayout
            #endif
        }
        .accessibilityIdentifier("onboarding.step.\(step.rawValue)")
    }

    #if os(macOS)
    private var macLayout: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 42)
                .padding(.top, 28)

            ScrollView {
                VStack(spacing: 0) {
                    stepCopy
                        .frame(maxWidth: 720)

                    artwork
                        .frame(width: 680, height: 320)
                        .padding(.top, 24)

                    stepDetails
                        .frame(maxWidth: 540)
                        .padding(.top, 22)

                    controls
                        .frame(width: 430)
                        .padding(.top, 28)
                }
                .padding(.horizontal, 56)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    #if os(iOS)
    private var mobileLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 8)

                artwork
                    .frame(height: 300)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 0) {
                    stepCopy
                    stepDetails
                        .padding(.top, 24)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            controls
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Divider().opacity(0.35)
                }
        }
    }
    #endif

    private var header: some View {
        HStack {
            BrieflyLogo()
            Spacer()
            if step != .depth {
                Button("Skip", action: complete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Skip welcome tour")
            }
        }
        .frame(minHeight: 44)
    }

    private var artwork: some View {
        ZStack {
            Ellipse()
                .fill(artworkTint)
                .padding(44)
                .blur(radius: 48)

            Group {
                switch step {
                case .welcome:
                    OnboardingWelcomeArtwork()
                case .capture:
                    OnboardingCaptureArtwork()
                case .depth:
                    OnboardingDepthArtwork(selection: $depth)
                }
            }
            .id(step)
            .transition(stepTransition)
            .padding(24)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.42), value: step)
    }

    private var stepCopy: some View {
        VStack(alignment: stepCopyAlignment, spacing: 13) {
            Text(step.eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Color.accentColor)

            Text(step.title)
                .font(titleFont)
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(stepCopyTextAlignment)
        .id("copy-\(step.rawValue)")
        .transition(stepTransition)
        .animation(reduceMotion ? nil : .snappy(duration: 0.36), value: step)
    }

    @ViewBuilder
    private var stepDetails: some View {
        switch step {
        case .welcome:
            HStack(spacing: 9) {
                OnboardingPill(icon: "link", label: "Links")
                OnboardingPill(icon: "doc.richtext", label: "PDFs")
                OnboardingPill(icon: "waveform", label: "Audio")
            }
        case .capture:
            VStack(spacing: 10) {
                #if os(macOS)
                OnboardingCapability(
                    icon: "command",
                    title: "Press ⌘G anywhere",
                    detail: "Capture the clipboard without breaking focus."
                )
                OnboardingCapability(
                    icon: "arrow.down.doc",
                    title: "Drop in a link or PDF",
                    detail: "Briefly starts processing it right away."
                )
                #else
                OnboardingCapability(
                    icon: "square.and.arrow.up",
                    title: "Share to Briefly",
                    detail: "Use the Share button in Safari and other apps."
                )
                OnboardingCapability(
                    icon: "plus",
                    title: "Capture inside the app",
                    detail: "Paste a link, add a PDF, or write a note."
                )
                #endif
                OnboardingCapability(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Follow the source",
                    detail: "Keep up with feeds, podcasts, and pages in one place."
                )
            }
        case .depth:
            HStack(spacing: 18) {
                OnboardingDepthLabel(icon: "text.alignleft", title: "Concise")
                OnboardingDepthLabel(icon: "text.justify", title: "Detailed")
                OnboardingDepthLabel(icon: "doc.text", title: "Source")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases) { candidate in
                    Capsule()
                        .fill(candidate == step ? Color.accentColor : Color.primary.opacity(0.16))
                        .frame(width: candidate == step ? 24 : 7, height: 7)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back", action: goBack)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }

                Button(action: advance) {
                    HStack(spacing: 8) {
                        Text(step == .depth ? "Continue to Briefly" : "Continue")
                        Image(systemName: step == .depth ? "checkmark" : "arrow.right")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
    }

    private var titleFont: Font {
        #if os(macOS)
        .system(size: 44, weight: .bold, design: .rounded)
        #else
        .system(size: 34, weight: .bold, design: .rounded)
        #endif
    }

    private var stepCopyAlignment: HorizontalAlignment {
        #if os(macOS)
        .center
        #else
        .leading
        #endif
    }

    private var stepCopyTextAlignment: TextAlignment {
        #if os(macOS)
        .center
        #else
        .leading
        #endif
    }

    private var artworkTint: Color {
        switch step {
        case .welcome: Color(red: 0.47, green: 0.28, blue: 0.94).opacity(0.10)
        case .capture: Color(red: 0.96, green: 0.41, blue: 0.24).opacity(0.10)
        case .depth: Color(red: 0.18, green: 0.57, blue: 0.51).opacity(0.10)
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func advance() {
        guard let next = step.next else {
            complete()
            return
        }
        movesForward = true
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.38)) {
            step = next
        }
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        movesForward = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.38)) {
            step = previous
        }
    }
}

private enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case capture
    case depth

    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var next: Self? { Self.allCases.dropFirst(index + 1).first }
    var previous: Self? { index > 0 ? Self.allCases[index - 1] : nil }

    var eyebrow: String {
        switch self {
        case .welcome: "WELCOME TO BRIEFLY"
        case .capture: "SAVE FROM ANYWHERE"
        case .depth: "READ ON YOUR TERMS"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Make space for what matters."
        case .capture:
            #if os(macOS)
            "Capture without breaking focus."
            #else
            "Keep the good stuff close."
            #endif
        case .depth: "Start with the point. Go deeper when it’s worth it."
        }
    }

    var detail: String {
        switch self {
        case .welcome:
            "Briefly turns articles, documents, and long listens into a calm personal library—clear enough to scan, rich enough to return to."
        case .capture:
            #if os(macOS)
            "A shortcut, a drop, or a followed source is all it takes. Briefly quietly prepares each item for later."
            #else
            "Send something to Briefly the moment it earns your attention. It will be ready when you have time for it."
            #endif
        case .depth:
            "Every item keeps its source beside a concise and detailed reading. Try the preview, then choose what the moment calls for."
        }
    }
}

private enum OnboardingDepth: String, CaseIterable, Identifiable {
    case concise
    case detailed
    case source

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .concise: "text.alignleft"
        case .detailed: "text.justify"
        case .source: "doc.text"
        }
    }

    var preview: String {
        switch self {
        case .concise:
            "Curiosity grows when ideas have somewhere to land. Save with intention, then return when a new thought makes the old one useful again."
        case .detailed:
            "A personal library turns passing attention into a practice. Capture the ideas worth returning to, connect them to questions you care about, and revisit them when new context changes what they mean."
        case .source:
            "Curiosity lasts when interesting ideas have somewhere to land. A personal library turns passing attention into questions you can return to. Save with intention, revisit what still matters, and connect each new insight to something you already know."
        }
    }
}

private struct OnboardingPill: View {
    let icon: String
    let label: String

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.08)) }
    }
}

private struct OnboardingCapability: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OnboardingDepthLabel: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}

private struct OnboardingWelcomeArtwork: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: sourceSpacing) {
                sourceTile(icon: "link", title: "Essay", color: .purple)
                sourceTile(icon: "waveform", title: "Podcast", color: .orange)
                sourceTile(icon: "doc.richtext", title: "Paper", color: .blue)
            }

            Image(systemName: "arrow.down")
                .font(arrowFont)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image("BrieflyMark")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("6 MIN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text("The idea, made clear")
                    .font(cardTitleFont)
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
                VStack(alignment: .leading, spacing: 7) {
                    line(width: 1)
                    line(width: 0.86)
                    line(width: 0.62)
                }
                Label("Ready to read", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.57, blue: 0.51))
            }
            .padding(cardPadding)
            .frame(
                width: resultCardWidth,
                height: resultCardHeight,
                alignment: .topLeading
            )
            .onboardingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.14))
            }
            .shadow(color: .black.opacity(0.13), radius: 15, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceTile(icon: String, title: String, color: Color) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(sourceTitleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(width: sourceTileWidth, height: sourceTileHeight)
        .onboardingGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.13))
        }
        #else
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(sourceTitleFont)
                .lineLimit(1)
        }
        .frame(width: sourceTileWidth, height: sourceTileHeight)
        .onboardingGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.13))
        }
        #endif
    }

    private func line(width: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: proxy.size.width * width, height: 6)
        }
        .frame(height: 6)
    }

    private var sourceSpacing: CGFloat {
        #if os(macOS)
        10
        #else
        7
        #endif
    }

    private var sourceTileWidth: CGFloat {
        #if os(macOS)
        116
        #else
        92
        #endif
    }

    private var sourceTileHeight: CGFloat {
        #if os(macOS)
        50
        #else
        54
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(macOS)
        20
        #else
        15
        #endif
    }

    private var resultCardWidth: CGFloat {
        #if os(macOS)
        350
        #else
        270
        #endif
    }

    private var resultCardHeight: CGFloat {
        #if os(macOS)
        174
        #else
        154
        #endif
    }

    private var sourceTitleFont: Font {
        #if os(macOS)
        .caption.weight(.semibold)
        #else
        .caption2.weight(.semibold)
        #endif
    }

    private var cardTitleFont: Font {
        #if os(macOS)
        .title3.weight(.bold)
        #else
        .headline.weight(.bold)
        #endif
    }

    private var arrowFont: Font {
        #if os(macOS)
        .title2.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }
}

private struct OnboardingCaptureArtwork: View {
    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7) {
                    Circle().fill(.red.opacity(0.7)).frame(width: 8, height: 8)
                    Circle().fill(.yellow.opacity(0.7)).frame(width: 8, height: 8)
                    Circle().fill(.green.opacity(0.7)).frame(width: 8, height: 8)
                    Text("A story worth keeping")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                    Spacer()
                }
                Text("Why the best ideas arrive when you’re busy")
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                HStack {
                    Label("readbriefly.fyi", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: 390)
            .onboardingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.14))
            }

            Image(systemName: "arrow.down")
                .font(.headline.weight(.bold))
                .foregroundStyle(.secondary)

            #if os(macOS)
            HStack(spacing: 13) {
                Text("⌘")
                Text("G")
            }
            .font(.system(size: 25, weight: .medium, design: .rounded))
            .padding(.horizontal, 20)
            .frame(height: 60)
            .onboardingGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            #else
            HStack(spacing: 11) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share to Briefly")
                        .font(.callout.weight(.bold))
                    Text("Saved for later")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.18, green: 0.57, blue: 0.51))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 300, minHeight: 62)
            .onboardingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.40), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingDepthArtwork: View {
    @Binding var selection: OnboardingDepth

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(OnboardingDepth.allCases) { depth in
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            selection = depth
                        }
                    } label: {
                        Label(depth.title, systemImage: depth.icon)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                selection == depth ? Color.accentColor.opacity(0.14) : .clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == depth ? Color.accentColor : .secondary)
                    .accessibilityAddTraits(selection == depth ? .isSelected : [])
                }
            }
            .padding(4)
            .onboardingGlass(in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.12)) }
            .frame(maxWidth: 430)

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("How Curiosity Becomes a Practice")
                            .font(.headline.weight(.bold))
                        Text(selection.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: selection.icon)
                        .foregroundStyle(.secondary)
                }

                Text(selection.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .contentTransition(.opacity)
                    .id(selection)

                Spacer(minLength: 0)

                HStack {
                    Label("Saved in your library", systemImage: "books.vertical.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "headphones")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 430, minHeight: 190, alignment: .topLeading)
            .onboardingGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.14))
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func onboardingGlass<S: Shape>(in shape: S) -> some View {
        #if os(macOS)
        macLiquidGlass(in: shape, interactive: false)
        #else
        mobileGlass(in: shape, interactive: false)
        #endif
    }
}
