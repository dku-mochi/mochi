import ActivityKit
import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

import CoreLiveActivity

/// 모찌 캡처 → 분석 진행 → 결과/선택 흐름을 표현하는 Live Activity.
///
/// Lock Screen 과 Dynamic Island 에 표시되며, App Intents 로 interactive button 을 제공한다
/// (iOS 17+). 헷갈려요(`needsReview`) 면 후보를 한 탭으로 선택, 아니면 저장 결과를 ambient 로 표시한다.
///
/// **Layout (좌측 세로 썸네일 column)**:
/// - Lock Screen: 좌측에 9:19.5 비율 스크린샷 썸네일 (46×100pt), 우측에 앱 아이콘 + phase 본문.
/// - Dynamic Island expanded: leading 에 작은 세로 썸네일 (28×60), trailing 에 phaseTag,
///   bottom 에 후보 row / 요약.
/// - 썸네일은 attributes 의 `thumbnailRelativePath` 를 App Group container 에서 디스크 read
///   (4KB payload 한도 우회). 비-스크린샷 채널은 nil → photo placeholder.
///
/// **3-phase UI**:
/// - `.analyzing`: spinner + "사용자 의도 분석 중…" 한 줄.
/// - `.ready` + `needsReview`: 후보 2개 가로 row + "다른 의도".
/// - `.ready` + 확정: "이렇게 저장했어요 — <요약>".
/// - `.confirmed`: 사용자가 선택한 라벨 + 체크. 잠시 후 모찌 앱이 Activity 를 dismiss.
struct MochiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MochiLiveActivityAttributes.self) { context in
            MochiLockScreenView(state: context.state, attributes: context.attributes)
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
                    phaseTagView(context.state)
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
    private func phaseTagView(_ state: MochiLiveActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .analyzing:
            Label("분석 중", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready:
            if state.needsReview {
                Label("선택 대기", systemImage: "hand.tap")
                    .font(.caption2)
                    .foregroundStyle(brandPrimary)
            } else {
                Label("저장됨", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        case .confirmed:
            Label("저장됨", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func compactTrailingView(state: MochiLiveActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .analyzing:
            ProgressView().controlSize(.mini).tint(.white)
        case .ready:
            if state.needsReview, let first = state.candidates.first {
                Text(first.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "checkmark")
            }
        case .confirmed:
            Image(systemName: "checkmark")
        }
    }

    @ViewBuilder
    private func expandedBottom(state: MochiLiveActivityAttributes.ContentState) -> some View {
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
            if state.needsReview, !state.candidates.isEmpty {
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
            } else {
                savedSummary(state.summary)
                    .padding(.top, 4)
            }
        case .confirmed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(state.selectedLabel ?? "기록") 로 저장됨")
                    .font(.footnote)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func savedSummary(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(summary.isEmpty ? "이렇게 저장했어요" : summary)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)
}

/// Lock Screen 펼침 view. 좌측 세로 썸네일 column + 우측 본문.
private struct MochiLockScreenView: View {
    let state: MochiLiveActivityAttributes.ContentState
    let attributes: MochiLiveActivityAttributes

    private let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)

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
    private var appIcon: some View {
        Image("AppIconImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .analyzing:
            HStack(spacing: 8) {
                appIcon
                ProgressView().controlSize(.small).tint(.white)
                Text("사용자 의도 분석 중…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .ready:
            if state.needsReview, !state.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        appIcon
                        Text(state.summary.isEmpty ? "어떤 의도로 남겼나요?" : state.summary)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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
                    .tint(.white)
                }
            } else {
                HStack(spacing: 8) {
                    appIcon
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(state.summary.isEmpty ? "이렇게 저장했어요" : state.summary)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
        case .confirmed:
            HStack(spacing: 6) {
                appIcon
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(state.selectedLabel ?? "기록") 로 저장됐어요")
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
            forSecurityApplicationGroupIdentifier: "group.app.mochi"
        ) else { return nil }
        let url = container.appendingPathComponent(relativePath)
        // 위젯/Live Activity 익스텐션은 메모리 예산이 매우 작다. 원본 스크린샷(≈1170×2532)을
        // 통째 디코드하면(≈12MB) 예산을 넘겨 iOS 가 렌더를 포기하고 placeholder 로 폴백한다.
        // 표시 크기(@3x)에 맞춰 ImageIO 로 다운샘플 디코드해 메모리를 표시 해상도 수준으로 묶는다.
        let maxPixel = Int(max(width, height) * 3)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
