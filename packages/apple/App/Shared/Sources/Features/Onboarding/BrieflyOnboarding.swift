import SwiftUI

struct BrieflyOnboarding: View {
    static let completionKey = "BrieflyOnboardingVersion"
    static let currentVersion = 4

    let complete: () -> Void

    var body: some View {
        #if os(iOS)
        MobileOnboarding(complete: complete)
        #else
        MacOnboarding(complete: complete)
        #endif
    }
}

#if os(iOS)
/// Three short screens that follow one example, a long essay, from saving it to
/// reading the summary to listening to it.
private struct MobileOnboarding: View {
    let complete: () -> Void
    @State private var page = 0

    private let pages: [(title: String, message: String)] = [
        ("Save it in a tap.", "Found a long read? Share it to Briefly."),
        ("Get the point.", "The 42-minute essay, in 30 seconds."),
        ("Or just listen.", "Every item can be read aloud.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrieflyLogo()
                Spacer()
                Button("Skip", action: complete)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Rectangle()
                        .fill(index == page ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 22 : 8, height: 4)
                }
            }
            .animation(.snappy, value: page)
            .accessibilityHidden(true)
            .padding(.bottom, 20)

            Button {
                if page == pages.count - 1 { complete() } else { page += 1 }
            } label: {
                Text(page == pages.count - 1 ? "Start reading" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .foregroundStyle(.background)
                    .background(Color.primary, in: Rectangle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .accessibilityIdentifier("onboarding.continue")
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .accessibilityIdentifier("onboarding.step.\(page)")
    }

    private func pageView(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 12)
            Group {
                switch index {
                case 0: SaveDemo(isActive: page == 0)
                case 1: SummaryDemo(isActive: page == 1)
                default: ListenDemo(isActive: page == 2)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 28)
            Text(pages[index].title)
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(pages[index].message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            if index == pages.count - 1 {
                Text("Summaries are made by Briefly on your Mac and sync here.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
    }
}

/// The example item used on every screen.
private enum OnboardingExample {
    static let title = "Why We Remember Stories"
    static let source = "longreads.example"
    static let concise =
        "Facts fade on their own. Stories last because they link each event to a cause and a consequence, which gives memory something to hold on to."
    static let detailed =
        "Memory is built for sequences. When information arrives as a chain of events — someone wants something, something stands in the way, something changes — each step cues the next. That is why a story told once is easier to recall than a list read three times, and why good teachers turn ideas into narratives."
}

/// A frosted, square card matching the app's surfaces.
private struct DemoCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shadow the frosted backing only, so it doesn't blend into the content
            // and solid chips keep full contrast.
            .background {
                Rectangle()
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
            }
    }
}

private struct SaveDemo: View {
    let isActive: Bool
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DemoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(OnboardingExample.source) · 42 min read")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(OnboardingExample.title)
                        .font(.title3.weight(.semibold))
                    Text("Every culture tells stories. The reason may be simpler than we think…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: saved ? "checkmark" : "square.and.arrow.up")
                    .font(.headline)
                    .contentTransition(.symbolEffect(.replace))
                Text(saved ? "Saved to Briefly" : "Share → Briefly")
                    .font(.headline)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .foregroundStyle(saved ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background {
                if saved {
                    Rectangle().fill(Color.primary)
                } else {
                    Rectangle().fill(.thinMaterial)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: isActive) {
            saved = false
            guard isActive else { return }
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.snappy) { saved = true }
        }
    }
}

private struct SummaryDemo: View {
    let isActive: Bool
    @State private var detailed = false
    @State private var userChose = false

    var body: some View {
        DemoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(OnboardingExample.title)
                    .font(.title3.weight(.semibold))
                Text("\(OnboardingExample.source) · 42 min read")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ChoiceChip(title: "Concise", isSelected: !detailed) { choose(false) }
                    ChoiceChip(title: "Detailed", isSelected: detailed) { choose(true) }
                }
                Text(detailed ? OnboardingExample.detailed : OnboardingExample.concise)
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(detailed)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: detailed)
        .task(id: isActive) {
            guard isActive else { return }
            // Show both depths once, then leave the choice to the reader.
            try? await Task.sleep(for: .seconds(2.2))
            if !userChose { detailed = true }
        }
    }

    private func choose(_ value: Bool) {
        userChose = true
        detailed = value
    }
}

private struct ListenDemo: View {
    let isActive: Bool
    @State private var playing = false
    @State private var progress = 0.12

    var body: some View {
        DemoCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Button {
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Color.accentColor, in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playing ? "Pause example" : "Play example")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OnboardingExample.title)
                            .font(.headline)
                        Text("Concise · 0:32")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing)
                        .accessibilityHidden(true)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.12))
                        Rectangle().fill(Color.primary)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .task(id: isActive) {
            playing = isActive
            progress = 0.12
            guard isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                if playing {
                    withAnimation(.linear(duration: 0.12)) {
                        progress = progress >= 1 ? 0 : progress + 0.012
                    }
                }
            }
        }
    }
}
#endif

#if os(macOS)
private struct MacOnboarding: View {
    let complete: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Briefly").font(.headline)
                Spacer()
                Button("Skip", action: complete)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            .padding(.vertical, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("\(step + 1) of 3")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(screens[step].title)
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(screens[step].introduction)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(screens[step].points.enumerated()), id: \.offset) { index, point in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .leading)
                                Text(point)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 28)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step == 2 ? "Open Briefly" : "Continue") {
                    if step == 2 { complete() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.continue")
            }
            .controlSize(.large)
            .padding(.vertical, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("onboarding.step.\(step)")
    }

    private let screens: [Screen] = [
        Screen(title: "Build your library on the Mac",
               introduction: "Add links, PDFs, or text to Briefly. Your Mac prepares them for reading.",
               points: [
                "Paste a link or text, import a PDF, or use the capture shortcut.",
                "Briefly extracts the content and creates concise and detailed summaries using your chosen AI.",
                "Read on your Mac. If you want to read on your phone too, your library can sync through iCloud."
               ]),
        Screen(title: "Set up AI processing",
               introduction: "Processing runs on this Mac. You choose the AI it uses.",
               points: [
                "Open Settings → AI Processing and sign in with OpenRouter.",
                "Choose your model and, when supported, its reasoning effort. Briefly saves these choices automatically.",
                "Keep Briefly running while it processes items. If something fails, the saved item stays in your library so you can retry."
               ]),
        Screen(title: "Read on your phone",
               introduction: "The iPhone and iPad apps are mainly for reading your library.",
               points: [
                "Use the same Apple Account for iCloud on both devices and enable iCloud for Briefly. Your Briefly sign-in is separate.",
                "Open Briefly on both devices to sync. Downloaded items are available to read offline.",
                "You can also send links, PDFs, or text from your phone to the Mac’s queue. That’s optional. The phone saves the original; the Mac extracts and summarizes it."
               ])
    ]

    private struct Screen {
        let title: String
        let introduction: String
        let points: [String]
    }
}
#endif
