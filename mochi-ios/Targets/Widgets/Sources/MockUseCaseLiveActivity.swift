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
/// **Layout (옵션 1 — 좌측 세로 썸네일 column)**:
/// - Lock Screen: 좌측에 9:19.5 비율 스크린샷 썸네일 (46×100pt), 우측에 앱 아이콘 + phase 본문.
/// - Dynamic Island expanded: leading 에 작은 세로 썸네일 (28×60), trailing 에 phaseTag,
///   bottom 에 후보 row + "다른 의도". leading + bottom 합산 ≈ 132pt < cap 144pt.
/// - 썸네일은 attributes 의 `thumbnailRelativePath` 를 App Group container 에서 디스크 read
///   (4KB payload 한도 우회). nil 이면 photo placeholder.
///
/// **3-phase UI**:
/// - `.analyzing`: spinner + "사용자 의도 분석 중…" 한 줄.
/// - `.ready`: top-1 prose + 후보 2개 가로 row + "다른 의도" 한 줄.
/// - `.confirmed`: 사용자가 선택한 라벨 + 체크. 잠시 후 모찌 앱이 Activity 를 dismiss.
struct MockUseCaseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MockUseCaseActivityAttributes.self) { context in
            MockUseCaseLockScreenView(state: context.state, attributes: context.attributes)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ThumbnailColumn(
                        relativePath: context.attributes.thumbnailRelativePath,
                        width: 28,
                        height: 60,
                        cornerRadius: 6
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    phaseTagView(context.state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(state: context.state)
                }
            } compactLeading: {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                compactTrailingView(state: context.state)
            } minimal: {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
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
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(state.candidates.prefix(2)) { c in
                        Button(intent: SelectCandidateIntent(label: c.label)) {
                            Text(c.label)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .tint(brandPrimary)
                        .buttonStyle(.borderedProminent)
                    }
                }
                Button(intent: OpenMochiOtherIntentIntent()) {
                    Text("다른 의도")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
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

/// Lock Screen 펼침 view. 좌측 세로 썸네일 column + 우측 본문.
private struct MockUseCaseLockScreenView: View {
    let state: MockUseCaseActivityAttributes.ContentState
    let attributes: MockUseCaseActivityAttributes

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailColumn(
                relativePath: attributes.thumbnailRelativePath,
                width: 46,
                height: 100,
                cornerRadius: 8
            )
            VStack(alignment: .leading, spacing: 6) {
                phaseBody
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .analyzing:
            HStack(spacing: 8) {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                ProgressView().controlSize(.small).tint(.white)
                Text("사용자 의도 분석 중…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let top = state.candidates.first {
                        Text("\"\(top.label)\" 이 그럴듯해요")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(state.candidates.prefix(2)) { c in
                        Button(intent: SelectCandidateIntent(label: c.label)) {
                            Text(c.label)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .tint(Color(red: 0.55, green: 0.46, blue: 0.93))
                        .buttonStyle(.borderedProminent)
                    }
                }
                Button(intent: OpenMochiOtherIntentIntent()) {
                    Text("다른 의도")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        case .confirmed:
            HStack(spacing: 6) {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(state.selectedLabel ?? "?") 로 저장됐어요")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
    }
}

/// 9:19.5 비율 (핸드폰 스크린샷) 세로 썸네일 column. `App Group container/relativePath` 의 PNG 를
/// 디스크에서 직접 읽어 4KB payload 한도 우회. nil 또는 read 실패 시 photo placeholder.
private struct ThumbnailColumn: View {
    let relativePath: String?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image = loadImage() {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.08))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
            )
    }

    private func loadImage() -> UIImage? {
        guard let relativePath else { return nil }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.IndexFinger.mochi"
        ) else { return nil }
        let url = container.appendingPathComponent(relativePath)
        return UIImage(contentsOfFile: url.path)
    }
}
