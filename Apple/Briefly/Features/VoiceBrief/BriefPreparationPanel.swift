import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

struct BriefPreparationPanel: View {
    @Bindable var model: LibraryModel
    let brief: LibraryVoiceBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRunningVoiceBrief,
               let progress = model.voiceBriefGenerationProgress,
               progress.voiceBriefID == brief.id {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Preparing your brief")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if progress.phase == .summarizing, progress.retrievedItemCount > 0 {
                            Text(
                                "\(progress.summarizedItemCount + progress.failedItemCount)" +
                                    "/\(progress.retrievedItemCount)"
                            )
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(brief.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    preparationStep(
                        title: "Gathering channel items",
                        detail: retrievalDetail(progress),
                        state: progress.phase == .retrieving ? .active : .complete
                    )
                    Divider().padding(.leading, 32)
                    preparationStep(
                        title: "Preparing summaries",
                        detail: summaryDetail(progress),
                        state: summaryState(progress)
                    )
                    Divider().padding(.leading, 32)
                    preparationStep(
                        title: "Writing your brief",
                        detail: "Creating short and detailed versions",
                        state: progress.phase == .assembling ? .active : .waiting
                    )
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prepare a new brief")
                        .font(.callout.weight(.semibold))
                    Text("Fetch the channels and assemble short and detailed versions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Button {
                    Task { await model.runSelectedVoiceBrief() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text("Prepare new brief")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .background(Color.blue, in: Capsule())
                .disabled(model.isRunningVoiceBrief || brief.sources.isEmpty)
            }
        }
        .padding(14)
        .background(
            model.isRunningVoiceBrief
                ? Color.accentColor.opacity(0.10)
                : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    model.isRunningVoiceBrief
                        ? Color.accentColor.opacity(0.28)
                        : Color.primary.opacity(0.08)
                )
        }
        .animation(.smooth(duration: 0.35), value: model.isRunningVoiceBrief)
        .animation(.smooth(duration: 0.25), value: model.status)
    }

    enum StepState {
        case waiting
        case active
        case complete
    }

    private func summaryState(_ progress: VoiceBriefGenerationProgress) -> StepState {
        switch progress.phase {
        case .retrieving: .waiting
        case .summarizing: .active
        case .assembling: .complete
        }
    }

    private func retrievalDetail(_ progress: VoiceBriefGenerationProgress) -> String {
        let channelLabel = progress.totalChannelCount == 1 ? "channel" : "channels"
        let itemLabel = progress.retrievedItemCount == 1 ? "item" : "items"
        if progress.phase == .retrieving {
            return "Checked \(progress.checkedChannelCount) of \(progress.totalChannelCount) " +
                "\(channelLabel) · \(progress.retrievedItemCount) new \(itemLabel)"
        }
        return "Retrieved \(progress.retrievedItemCount) new \(itemLabel) from " +
            "\(progress.totalChannelCount) \(channelLabel)"
    }

    private func summaryDetail(_ progress: VoiceBriefGenerationProgress) -> String {
        guard progress.phase != .retrieving else { return "Waiting for new items" }
        guard progress.retrievedItemCount > 0 else { return "No new items to summarize" }
        if progress.failedItemCount > 0 {
            return "\(progress.summarizedItemCount) summarized · " +
                "\(progress.failedItemCount) unavailable"
        }
        return "\(progress.summarizedItemCount) of \(progress.retrievedItemCount) summarized"
    }

    @ViewBuilder
    private func preparationStep(
        title: String,
        detail: String,
        state: StepState
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch state {
                case .waiting:
                    Circle()
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                }
            }
            .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(state == .active ? .semibold : .medium))
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}
