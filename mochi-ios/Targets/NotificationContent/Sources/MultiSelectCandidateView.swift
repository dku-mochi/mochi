import SwiftUI
import CoreLiveActivity

/// 알림 펼침 시 알림 안에 표시되는 multi-select 후보 UI.
///
/// 사용자가 알림을 길게 누르거나 swipe down 하면 시스템이 `NotificationViewController`
/// 안에 본 view 를 띄운다. 사용자는 모찌 앱을 열지 않고 알림 안에서 후보를 multi-select
/// 한 뒤, "확인" 버튼은 통합 액션 버튼 영역에 띄워진다 (system 이 그 영역을 별도로 관리).
///
/// **자유 텍스트 입력은 안 됨** — Apple design. "다른 의도" 는 별도 액션 버튼으로 노출되어
/// 누르면 모찌 앱 진입.
///
/// 본 prototype 은 선택 상태를 *로컬로만* 표시하고 commit 은 안 한다 — 알림 안에서 SwiftUI
/// 의 `Button` 이 host UIHostingController 의 lifecycle 안에서만 동작하기 때문이다. 진짜
/// commit 은 시스템 액션 버튼 (UNNotificationAction) 에서 발사된다. prototype 의 목적은
/// "느낌" 확인이라 visual 만 제공.
struct MultiSelectCandidateView: View {
    let caption: String
    let candidates: [MockUseCaseActivityAttributes.Candidate]

    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 8) {
                ForEach(candidates) { c in
                    candidateRow(c)
                }
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🐹 모찌에 어떻게 남기시겠어요?")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color(uiColor: .label))
            Text(caption)
                .font(.system(.subheadline, design: .default))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineLimit(1)
        }
    }

    private func candidateRow(_ c: MockUseCaseActivityAttributes.Candidate) -> some View {
        let isSelected = selected.contains(c.label)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isSelected ? brandPrimary : Color(uiColor: .tertiaryLabel))

            VStack(alignment: .leading, spacing: 2) {
                Text(c.label)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                Text(intentReadable(c.intent))
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer(minLength: 0)
            applicabilityBar(c.applicability)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? brandPrimary.opacity(0.10) : Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? brandPrimary.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(c.label) } else { selected.insert(c.label) }
        }
    }

    private func applicabilityBar(_ value: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(uiColor: .quaternaryLabel))
                .frame(width: 38, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(brandPrimary)
                .frame(width: 38 * max(0, min(1, value)), height: 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if selected.isEmpty {
                Text("탭해서 의도를 선택하세요. 여러 개 가능.")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            } else {
                Text("\(selected.count)개 선택됨 — 알림 액션 버튼으로 저장하세요")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(brandPrimary)
            }
            Spacer(minLength: 0)
        }
    }

    private func intentReadable(_ intent: String) -> String {
        switch intent {
        case "schedule":  return "일정"
        case "todo":      return "할 일"
        case "knowledge": return "지식"
        case "memo":      return "기록"
        default:          return intent
        }
    }

    private let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)
}
