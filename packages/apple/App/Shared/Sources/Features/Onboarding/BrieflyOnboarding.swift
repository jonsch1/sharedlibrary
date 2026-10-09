import SwiftUI

struct BrieflyOnboarding: View {
    static let completionKey = "BrieflyOnboardingVersion"
    static let currentVersion = 4

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
                    Text(title)
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(introduction)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
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

    private var title: String { screens[step].title }
    private var introduction: String { screens[step].introduction }
    private var points: [String] { screens[step].points }

    private var screens: [Screen] {
        #if os(macOS)
        [
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
        #else
        [
            Screen(title: "Read your library on your phone",
                   introduction: "Your Mac prepares the library. The phone app lets you read it wherever you are.",
                   points: [
                    "Add links, PDFs, and text in Briefly on your Mac. It extracts the content and creates summaries.",
                    "On your phone, choose the concise summary, detailed summary, or original source.",
                    "You can also send new items from your phone to the Mac’s queue, but you don’t need to."
                   ]),
            Screen(title: "Sync your library",
                   introduction: "Briefly uses iCloud to keep the Mac and phone libraries in sync.",
                   points: [
                    "Use the same Apple Account for iCloud on both devices and enable iCloud for Briefly. Signing in to Briefly is separate.",
                    "Open Briefly on both devices to sync new items and changes.",
                    "Downloaded items are available offline. You don’t need to keep your Mac awake to read them."
                   ]),
            Screen(title: "You can also save from your phone",
                   introduction: "If you find something while browsing, send it to Briefly for your Mac to process later.",
                   points: [
                    "Share a link, PDF, or text to Briefly, or add it inside the app. The original is saved immediately, even offline.",
                    "Open Briefly on your phone after sharing to sync the item to the queue. It stays pending until your Mac can process it.",
                    "Your Mac needs Briefly running and AI processing set up. The phone doesn’t extract or summarize anything. When the results sync back, you can read them here."
                   ])
        ]
        #endif
    }

    private struct Screen {
        let title: String
        let introduction: String
        let points: [String]
    }
}
