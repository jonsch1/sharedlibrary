import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        LibraryDetail(
            model: model,
            audioPlayer: audioPlayer,
            audioEntry: $audioEntry
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.workflows.navigateBack()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

#endif
