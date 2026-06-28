import SwiftUI
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import DesignSystem

/// "예정된 알림" 섹션 — 모찌가 보낼 예정인 미래 마감·일정 알림을 미리 보여줘 안심시킨다
/// ("언제 올지 모르는 불안"을 없앤다). 모찌가 정한 시각이라, 사용자는 빈 폼이 아니라 이미 정해진
/// 일정 위에서 끄거나(veto) 옮기기(reschedule)만 한다 — "모찌가 정하고, 나는 조정한다".
///
/// 같은 일정(`intentID`)에 모찌가 D-단계별로 여러 번 알림을 잡으므로, **한 일정 = 한 카드**로 묶고
/// 다음 1건만 펼쳐 보인다("앞으로 N번 더" → 탭하면 단계별로 펼쳐지고 개별로 끌 수 있다).
/// 왼쪽은 원본 캡처 썸네일(없으면 카테고리/종류 아이콘) — 내용으로만 보던 알림을 한눈에 구분.
struct UpcomingNotificationsView: View {
    let entries: [UpcomingNotificationDTO]
    let thumbnails: [UUID: ImageRef]
    let categories: [UUID: String]
    let onVeto: (UUID) -> Void
    let onReschedule: (UUID, Date) -> Void

    /// "직접 고르기" DatePicker 시트 대상(eventID + 현재 발송 예정 시각으로 초기값).
    @State private var pickerTarget: UpcomingNotificationDTO?

    private struct NotifGroup: Identifiable {
        let items: [UpcomingNotificationDTO]   // fireAt 오름차순, [0] = 가장 가까운 다음 알림(head)
        var id: UUID { items[0].eventID }
    }

    /// 같은 일정(intentID)의 알림을 묶는다. intentID 없으면 eventID 단독 묶음.
    /// 각 묶음 내부는 fireAt 오름차순, 묶음들도 head(가장 가까운) fireAt 오름차순.
    private var groups: [NotifGroup] {
        var byKey: [String: [UpcomingNotificationDTO]] = [:]
        var order: [String] = []
        for e in entries {
            let key = e.intentID?.uuidString ?? e.eventID.uuidString
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        return order
            .compactMap { key -> NotifGroup? in
                guard let items = byKey[key], !items.isEmpty else { return nil }
                return NotifGroup(items: items.sorted { $0.fireAt < $1.fireAt })
            }
            .sorted { $0.items[0].fireAt < $1.items[0].fireAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            header
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(groups) { group in
                    UpcomingGroupCard(
                        items: group.items,
                        thumbnails: thumbnails,
                        categories: categories,
                        onVeto: onVeto,
                        onPickExact: { pickerTarget = $0 },
                        onPreset: { onReschedule($0, $1) }
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
            Text("모찌가 이때 알려드릴게요")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 묶음 카드 (한 일정 = 한 카드: head + 펼침 하위 단계)

/// 같은 일정의 알림 묶음 1개 — 다음 1건(head)을 카드로, 나머지는 "앞으로 N번 더"로 접어 둔다.
/// head 의 미루기·끄기는 큰 액션, 하위 단계는 펼쳤을 때 개별 끄기만.
private struct UpcomingGroupCard: View {
    let items: [UpcomingNotificationDTO]
    let thumbnails: [UUID: ImageRef]
    let categories: [UUID: String]
    let onVeto: (UUID) -> Void
    let onPickExact: (UpcomingNotificationDTO) -> Void
    let onPreset: (UUID, Date) -> Void

    @State private var expanded = false

    private var head: UpcomingNotificationDTO { items[0] }
    private var rest: [UpcomingNotificationDTO] { Array(items.dropFirst()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
                NotifThumbnail(itemID: head.itemID, kind: head.kind, thumbnails: thumbnails, categories: categories)

                VStack(alignment: .leading, spacing: 5) {
                    if head.kind == "spaced" { recallBadge }
                    Text(head.title)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                    Text(head.body)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    fireAtLabel(head.fireAt)
                    if let original = head.originalFireAt { movedBadge(from: original) }
                    if !rest.isEmpty { moreToggle }
                }

                Spacer(minLength: HomeDesign.Spacing.sm)

                actions(for: head)
            }

            if expanded {
                ForEach(rest) { sub in substepRow(sub) }
            }
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

    /// "앞으로 N번 더 알려드려요" — 탭하면 하위 단계가 펼쳐진다.
    private var moreToggle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9.5, weight: .bold))
                Text("앞으로 \(rest.count)번 더 알려드려요")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(HomeDesign.Color.purple500)
            .padding(.horizontal, HomeDesign.Spacing.sm)
            .padding(.vertical, 5)
            .background(Capsule().fill(HomeDesign.Color.purple500.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
        .padding(.top, 2)
        .accessibilityLabel("이 일정 알림 \(rest.count)개 더 보기")
    }

    /// 펼친 하위 단계 1행 — 날짜 + 본문 + 그 단계만 끄기.
    private func substepRow(_ sub: UpcomingNotificationDTO) -> some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Text(Self.subDateFormatter.string(from: sub.fireAt))
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.sky400)
                .multilineTextAlignment(.center)
                .frame(width: 38)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HomeDesign.Color.sky100))

            Text(sub.body)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button { onVeto(sub.eventID) } label: {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.blush400)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(HomeDesign.Color.blush400.opacity(0.12)))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("이 알림만 끄기")
        }
        .padding(.top, HomeDesign.Spacing.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(HomeDesign.Color.border).frame(height: 0.5)
                .padding(.leading, 38 + HomeDesign.Spacing.sm)
        }
    }

    /// spaced(회수 정착) 알림 표식 — "마감 리마인드"가 아니라 "다시 보기"임을 구분(회수 보라 톤).
    private var recallBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 8.5, weight: .bold))
            Text("다시 보기")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(HomeDesign.Color.purple500)
        .padding(.horizontal, HomeDesign.Spacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(HomeDesign.Color.purple500.opacity(0.12)))
    }

    /// 발송 예정 상대 라벨 — DueDisplay 의 일정 시각 언어 + 긴급도 색을 그대로 쓴다(같은 시각 언어).
    private func fireAtLabel(_ date: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(DueDisplay.scheduleLabel(date))
                .font(.system(size: 12, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(DueDisplay.deadlineColor(date))
        .padding(.horizontal, HomeDesign.Spacing.sm)
        .padding(.vertical, 4)
        .background(Capsule().fill(DueDisplay.deadlineColor(date).opacity(0.12)))
    }

    /// "원래 X → 옮김" — 모찌 원안 대비 사용자가 옮겼음을 작게 표기.
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

    // MARK: head 2액션 — 미루기(프리셋 Menu) · 끄기(destructive)

    private func actions(for entry: UpcomingNotificationDTO) -> some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            Menu {
                ForEach(ReschedulePreset.all) { preset in
                    Button {
                        onPreset(entry.eventID, preset.fireAt(from: entry.fireAt))
                    } label: {
                        Label(preset.title, systemImage: preset.icon)
                    }
                }
                Divider()
                Button { onPickExact(entry) } label: {
                    Label("직접 고르기", systemImage: "calendar")
                }
            } label: {
                actionChip(icon: "clock.arrow.circlepath", tint: HomeDesign.Color.purple500)
            }
            .accessibilityLabel("알림 시간 미루기")

            Button { onVeto(entry.eventID) } label: {
                actionChip(icon: "bell.slash.fill", tint: HomeDesign.Color.blush400)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(entry.kind == "spaced" ? "이번 알림만 건너뛰기" : "이 알림 끄기")
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

    private static let subDateFormatter = DateFormatter.mochiSeoul("M/d")
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
    let intentA = UUID()
    return ScrollView {
        UpcomingNotificationsView(
            entries: [
                UpcomingNotificationDTO(
                    eventID: UUID(), kind: "deadline",
                    fireAt: Date().addingTimeInterval(60 * 60 * 26),
                    title: "리포트 제출", body: "내일이 마감이에요. 잊지 않게 알려드릴게요.",
                    originalFireAt: nil, intentID: UUID()
                ),
                UpcomingNotificationDTO(
                    eventID: UUID(), kind: "nudge",
                    fireAt: Date().addingTimeInterval(60 * 60 * 24 * 5),
                    title: "핀다이렉트 요금제 변경 확인", body: "변경할 요금제를 미리 확인해보면 좋아요.",
                    originalFireAt: nil, intentID: intentA
                ),
                UpcomingNotificationDTO(
                    eventID: UUID(), kind: "nudge",
                    fireAt: Date().addingTimeInterval(60 * 60 * 24 * 30),
                    title: "핀다이렉트 요금제 변경 확인", body: "예정일이 일주일 앞으로 다가왔습니다.",
                    originalFireAt: nil, intentID: intentA
                ),
                UpcomingNotificationDTO(
                    eventID: UUID(), kind: "nudge",
                    fireAt: Date().addingTimeInterval(60 * 60 * 24 * 37),
                    title: "핀다이렉트 요금제 변경 확인", body: "오늘 요금제 변경을 진행하시겠어요?",
                    originalFireAt: nil, intentID: intentA
                ),
            ],
            thumbnails: [:],
            categories: [:],
            onVeto: { _ in },
            onReschedule: { _, _ in }
        )
        .padding()
    }
    .background(HomeDesign.Color.bg)
}
