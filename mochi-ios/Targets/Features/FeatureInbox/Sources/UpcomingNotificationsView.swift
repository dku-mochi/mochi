import SwiftUI
import ComposableArchitecture
import CoreNetworking
import DesignSystem

/// 홈 "예정된 알림" 섹션 — 모찌가 보낼 예정인 미래 마감·일정 알림을 미리 보여줘 안심시킨다
/// ("언제 올지 모르는 불안"을 없앤다). 모찌가 정한 시각이라, 사용자는 빈 폼이 아니라 이미 정해진
/// 일정 위에서 끄거나(veto) 옮기기(reschedule)만 한다 — "모찌가 정하고, 나는 조정한다".
///
/// 시선 위계상 회수 히어로보다 약하다(안전망 톤): 작은 시각 타일 + title/body + 3액션 행.
/// pending 0건이면 호출부가 섹션 자체를 숨긴다(빈 자리를 만들지 않는다 — 안심).
struct UpcomingNotificationsView: View {
    let entries: [UpcomingNotificationDTO]
    let onVeto: (UUID) -> Void
    let onReschedule: (UUID, Date) -> Void

    /// "직접 고르기" DatePicker 시트 대상(eventID + 현재 발송 예정 시각으로 초기값).
    @State private var pickerTarget: UpcomingNotificationDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            header
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(entries) { entry in
                    UpcomingRow(
                        entry: entry,
                        onVeto: { onVeto(entry.eventID) },
                        onPickExact: { pickerTarget = entry },
                        onPreset: { onReschedule(entry.eventID, $0) }
                    )
                }
            }
        }
        .sheet(item: $pickerTarget) { target in
            ReschedulePickerSheet(entry: target) { newFireAt in
                onReschedule(target.eventID, newFireAt)
                pickerTarget = nil
            }
        }
    }

    /// 섹션 헤더 — "예정된 알림" + 모찌가 알려준다는 안심 보조문구. SectionHeader 패턴.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                Text("예정된 알림")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
            }
            Text("모찌가 이때 한 번 알려드릴게요")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 행

/// 예정 알림 1건 — 좌측 시각 타일 + title/body + 조정 표기 + 우측 3액션.
private struct UpcomingRow: View {
    let entry: UpcomingNotificationDTO
    let onVeto: () -> Void
    let onPickExact: () -> Void
    let onPreset: (Date) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            ScheduleDateTile(date: entry.fireAt)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)

                Text(entry.body)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                fireAtLabel

                if let original = entry.originalFireAt {
                    movedBadge(from: original)
                }
            }

            Spacer(minLength: HomeDesign.Spacing.sm)

            actions
        }
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .cardShadow()
    }

    /// 발송 예정 상대 라벨 — DueDisplay 의 일정 시각 언어 + 긴급도 색을 그대로 쓴다(같은 시각 언어).
    private var fireAtLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(DueDisplay.scheduleLabel(entry.fireAt))
                .font(.system(size: 12, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(DueDisplay.deadlineColor(entry.fireAt))
        .padding(.horizontal, HomeDesign.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(DueDisplay.deadlineColor(entry.fireAt).opacity(0.12))
        )
    }

    /// "원래 X → 옮김" — 모찌 원안 대비 사용자가 옮겼음을 작게 표기("모찌가 정하고, 내가 조정" 느낌).
    private func movedBadge(from original: Date) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.uturn.right")
                .font(.system(size: 8.5, weight: .bold))
            Text("원래 \(DueDisplay.scheduleLabel(original)) → 옮김")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(HomeDesign.Color.ink500)
    }

    // MARK: 3액션 — 다음에(프리셋 Menu) · 직접 고르기 · 끄기(destructive)

    private var actions: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            Menu {
                ForEach(ReschedulePreset.all) { preset in
                    Button {
                        onPreset(preset.fireAt(from: entry.fireAt))
                    } label: {
                        Label(preset.title, systemImage: preset.icon)
                    }
                }
                Divider()
                Button {
                    onPickExact()
                } label: {
                    Label("직접 고르기", systemImage: "calendar")
                }
            } label: {
                actionChip(icon: "clock.arrow.circlepath", tint: HomeDesign.Color.purple500)
            }
            .accessibilityLabel("알림 시간 미루기")

            Button(action: onVeto) {
                actionChip(icon: "bell.slash.fill", tint: HomeDesign.Color.blush400)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("이 알림 끄기")
        }
    }

    private func actionChip(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(Circle().fill(tint.opacity(0.12)))
            .overlay(Circle().stroke(tint.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - 프리셋 (다음에)

/// "다음에" 프리셋 — 현재 발송 예정 시각 기준 상대 이동(+1일/+3일/다음주). KST 고정.
private struct ReschedulePreset: Identifiable {
    let id: String
    let title: String
    let icon: String
    let make: (Date) -> Date

    func fireAt(from current: Date) -> Date { make(current) }

    static let all: [ReschedulePreset] = [
        ReschedulePreset(id: "d1", title: "내일로", icon: "1.circle") {
            Calendar.mochiSeoul.date(byAdding: .day, value: 1, to: $0) ?? $0
        },
        ReschedulePreset(id: "d3", title: "3일 뒤로", icon: "3.circle") {
            Calendar.mochiSeoul.date(byAdding: .day, value: 3, to: $0) ?? $0
        },
        ReschedulePreset(id: "w1", title: "다음 주로", icon: "calendar") {
            Calendar.mochiSeoul.date(byAdding: .day, value: 7, to: $0) ?? $0
        },
    ]
}

// MARK: - 직접 고르기 (DatePicker 시트)

/// "직접 고르기" 시트 — 모찌가 정한 시각 위에서 사용자가 원하는 시각을 직접 고른다.
/// 과거는 못 고르게 막는다(서버도 422). `AddScheduleForm` + `presentationDetents` 패턴.
private struct ReschedulePickerSheet: View {
    let entry: UpcomingNotificationDTO
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Date

    init(entry: UpcomingNotificationDTO, onSave: @escaping (Date) -> Void) {
        self.entry = entry
        self.onSave = onSave
        // 초기값은 현재 발송 예정 시각(미래라면 그대로, 혹시 과거면 지금 이후로).
        _selected = State(initialValue: max(entry.fireAt, Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            HStack {
                Text("언제 알려드릴까요?")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Spacer()
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .lineLimit(1)
                    .padding(.horizontal, HomeDesign.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(HomeDesign.Color.purple100.opacity(0.7)))
            }

            DatePicker(
                "",
                selection: $selected,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(HomeDesign.Color.purple500)

            Spacer(minLength: 0)

            Button {
                onSave(selected)
            } label: {
                Text("이때 알림 받기")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
            }
            .buttonStyle(PressableStyle())
        }
        .padding(HomeDesign.Spacing.xl)
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        UpcomingNotificationsView(
            entries: [
                UpcomingNotificationDTO(
                    eventID: UUID(),
                    kind: "deadline",
                    fireAt: Date().addingTimeInterval(60 * 60 * 26),
                    title: "리포트 제출",
                    body: "내일이 마감이에요. 잊지 않게 알려드릴게요.",
                    originalFireAt: nil
                ),
                UpcomingNotificationDTO(
                    eventID: UUID(),
                    kind: "nudge",
                    fireAt: Date().addingTimeInterval(60 * 60 * 24 * 4),
                    title: "치과 예약",
                    body: "다가오는 일정을 미리 챙겨드릴게요.",
                    originalFireAt: Date().addingTimeInterval(60 * 60 * 24 * 2)
                ),
            ],
            onVeto: { _ in },
            onReschedule: { _, _ in }
        )
        .padding()
    }
    .background(HomeDesign.Color.bg)
}
