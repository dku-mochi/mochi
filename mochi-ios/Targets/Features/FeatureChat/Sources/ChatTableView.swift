import DesignSystem
import SwiftUI

/// 말풍선 안 마크다운 표 — 칼럼은 내용 폭대로 잡히고, 버블보다 넓으면 가로 스크롤.
/// 헤더는 퍼플 틴트로 구분하고 행 사이엔 헤어라인 — 본문 버블(화이트 카드)과 톤을 맞춘다.
struct ChatTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], isHeader: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            cell(rows[row][column], isHeader: false)
                        }
                    }
                }
            }
            .background(HomeDesign.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .padding(1) // stroke 가 클립에 잘리지 않게
        }
    }

    private func cell(_ text: AttributedString, isHeader: Bool) -> some View {
        Text(ChatMarkup.resolvingBold(text, size: 13.5))
            .font(.system(size: 13.5, weight: isHeader ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isHeader ? HomeDesign.Color.ink700 : HomeDesign.Color.textPrimary)
            .lineSpacing(3)
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHeader ? HomeDesign.Color.purple50 : .clear)
    }
}

#Preview {
    ChatTableView(
        header: [AttributedString("이름"), AttributedString("가격"), AttributedString("메모")],
        rows: [
            [AttributedString("모찌"), AttributedString("1,000원"), AttributedString("쫀득함")],
            [AttributedString("도넛"), AttributedString("2,500원"), AttributedString("달콤하고 부드럽고 아주 길게 쓴 메모입니다")],
        ]
    )
    .padding()
}
