import SwiftUI
import CoreDomain
import CorePersistence
import DesignSystem

struct ShareEntryView: View {
    let initialURL: URL?
    let initialText: String?
    let imageRefs: [ImageRef]
    let channelGuess: IngestChannel
    let onSubmit: (InboundIngestPayload) -> Void
    let onCancel: () -> Void

    @State private var memo: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("들어온 내용") {
                    if let url = initialURL {
                        Text(url.absoluteString).font(.footnote)
                    }
                    if let text = initialText, !text.isEmpty {
                        Text(text).font(.footnote).lineLimit(4)
                    }
                    if !imageRefs.isEmpty {
                        Text("이미지 \(imageRefs.count)장 (\(totalImageMB)MB)")
                            .font(.footnote)
                            .foregroundStyle(MochiTheme.Palette.textSecondary)
                    }
                    if initialURL == nil && (initialText?.isEmpty ?? true) && imageRefs.isEmpty {
                        Text("(첨부된 내용 없음 — 메모만 저장됩니다)")
                            .font(MochiTheme.Typography.caption)
                            .foregroundStyle(MochiTheme.Palette.textSecondary)
                    }
                }
                Section("메모 (선택)") {
                    TextEditor(text: $memo).frame(minHeight: 100)
                }
                Section {
                    Text("입력 즉시 모찌가 자동으로 분석·분류합니다.")
                        .font(MochiTheme.Typography.caption)
                        .foregroundStyle(MochiTheme.Palette.textSecondary)
                }
            }
            .navigationTitle("모찌에 저장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("취소", action: onCancel) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        onSubmit(InboundIngestPayload(
                            url: initialURL,
                            text: initialText,
                            userMemo: memo.isEmpty ? nil : memo,
                            channelGuess: channelGuess,
                            imageRefs: imageRefs
                        ))
                    }
                }
            }
        }
    }

    private var totalImageMB: String {
        let bytes = imageRefs.reduce(0) { $0 + $1.byteSize }
        return String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }
}
