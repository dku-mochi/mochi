import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

import CoreLiveActivity

/// 모찌 백탭 → 분석 진행 → 결과 선택 흐름을 표현하는 Live Activity.
///
/// Lock Screen 과 Dynamic Island 에 표시되며, App Intents 로 interactive button 을 제공한다
/// (iOS 17+). 사용자는 모찌 앱을 열지 않고 Lock Screen 에서 의도를 한 탭으로 confirm 한다.
///
/// **3-phase UI**:
/// - `.analyzing`: spinner + "🐹 모찌 분석 중…" 한 줄. 캡쳐 직후 ~3-10초.
/// - `.ready`: top-1 후보 강조 + "확인" / "다른 의도" 두 버튼. dominant 가 명확한 케이스에선
///   여기서 single-tap 으로 끝난다.
/// - `.confirmed`: 사용자가 선택한 라벨 + 체크. 잠시 후 모찌 앱이 Activity 를 dismiss.
///
/// Dynamic Island 의 compact / minimal / expanded 도 같은 phase 로 분기.
struct MockUseCaseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MockUseCaseActivityAttributes.self) { context in
            // Lock Screen / Notification Center 의 expanded view.
            MockUseCaseLockScreenView(state: context.state, attributes: context.attributes)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("🐹")
                        .font(.system(size: 30))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    phaseTagView(context.state.phase)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.captureCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(state: context.state)
                }
            } compactLeading: {
                Text("🐹")
            } compactTrailing: {
                compactTrailingView(state: context.state)
            } minimal: {
                Text("🐹")
            }
        }
    }

    @ViewBuilder
    private func phaseTagView(_ phase: MockUseCaseActivityAttributes.Phase) -> some View {
        switch phase {
        case .analyzing:
            Label("분석 중", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready:
            Label("선택 대기", systemImage: "hand.tap")
                .font(.caption2)
                .foregroundStyle(brandPrimary)
        case .confirmed:
            Label("저장됨", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func compactTrailingView(state: MockUseCaseActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .analyzing:
            ProgressView().controlSize(.mini).tint(.white)
        case .ready:
            Text(state.candidates.first?.label ?? "?")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        case .confirmed:
            Image(systemName: "checkmark")
        }
    }

    @ViewBuilder
    private func expandedBottom(state: MockUseCaseActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("사용자 의도 분석 중…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        case .ready:
            HStack(spacing: 8) {
                ForEach(state.candidates.prefix(2)) { c in
                    Button(intent: SelectCandidateIntent(label: c.label)) {
                        Text(c.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .tint(brandPrimary)
                    .buttonStyle(.borderedProminent)
                }
                Button(intent: OpenMochiOtherIntentIntent()) {
                    Text("다른 의도")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        case .confirmed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(state.selectedLabel ?? "?") 로 저장됨")
                    .font(.footnote)
            }
            .padding(.top, 4)
        }
    }

    private let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)
}

/// Lock Screen 펼침 view. Dynamic Island 의 expanded 와 같은 정보지만 더 넉넉한 layout.
private struct MockUseCaseLockScreenView: View {
    let state: MockUseCaseActivityAttributes.ContentState
    let attributes: MockUseCaseActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("🐹")
                    .font(.system(size: 22))
                Text("모찌")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                phaseTag
            }
            Text(attributes.captureCaption)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            phaseBody
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var phaseTag: some View {
        switch state.phase {
        case .analyzing:
            Label("분석 중", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        case .ready:
            Label("선택", systemImage: "hand.tap")
                .font(.caption2)
                .foregroundStyle(Color(red: 0.75, green: 0.7, blue: 0.98))
        case .confirmed:
            Label("저장됨", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("사용자 의도 분석 중…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                if let top = state.candidates.first {
                    Text("가장 그럴듯한 건 \"\(top.label)\"")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                }
                HStack(spacing: 8) {
                    ForEach(state.candidates.prefix(2)) { c in
                        Button(intent: SelectCandidateIntent(label: c.label)) {
                            Text(c.label)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                        }
                        .tint(Color(red: 0.55, green: 0.46, blue: 0.93))
                        .buttonStyle(.borderedProminent)
                    }
                    Button(intent: OpenMochiOtherIntentIntent()) {
                        Text("다른 의도")
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        case .confirmed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(state.selectedLabel ?? "?") 로 저장됐어요")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
    }
}
