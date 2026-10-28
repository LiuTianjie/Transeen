import SwiftUI

/// A readable, selectable copy of every OCR block, including translations that
/// cannot fit inside the screenshot. The original image remains untouched.
struct CaptureTranscript: View {
    @Bindable var state: CaptureState
    var copy: () -> Void
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.hasTranslatedOnce ? "完整译文" : "识别文字").font(.system(size: 15, weight: .semibold))
                    Text(state.direction).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("对照原文", isOn: $showsOriginal).toggleStyle(.checkbox).controlSize(.small)
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(state.textBlocks) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            if showsOriginal, let translation = block.translation, translation != block.original {
                                Text(block.original).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Text(block.translation ?? block.original)
                                .font(.system(size: 14)).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.textSelection(.enabled)
                    }
                }.padding(16)
            }.frame(maxHeight: 380)
            Divider()
            HStack {
                Text("文字可选择、复制").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Label(state.textCopyCompleted ? "已复制" : "复制文字", systemImage: state.textCopyCompleted ? "checkmark" : "doc.on.doc")
                }.controlSize(.small)
            }.padding(12)
        }.frame(width: 420)
            .onDisappear { state.textCopyCompleted = false }
    }
}
