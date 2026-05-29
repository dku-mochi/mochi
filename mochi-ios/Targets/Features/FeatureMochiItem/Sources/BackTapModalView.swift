import SwiftUI
import ComposableArchitecture
import DesignSystem

/// 백탭 snippet 의 **메모** 분기에서 떠오르는 풀스크린 모달 — `BackTapModalFeature` 의 시각화.
///
/// 캡쳐 분기는 더 이상 이 모달이 다루지 않는다 (snippet 카드 안에서 background commit).
/// 본 view 는 textarea + 저장 진행 표시 + 취소만 한다.
public struct BackTapModalView: View {
    @Bindable public var store: StoreOf<BackTapModalFeature>

    public init(store: StoreOf<BackTapModalFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: MochiTheme.Spacing.xl) {
                Spacer(minLength: MochiTheme.Spacing.xl)

                // 자산 통합 전까지 placeholder. mochi2 / mochi-hello 자산을
                // DesignSystem 모듈로 옮기면 그때 Image("mochi2") 로 교체.
                Circle()
                    .fill(MochiTheme.Palette.primary.opacity(0.18))
                    .frame(width: 140, height: 140)
                    .overlay(
                        Text("🍡")
                            .font(.system(size: 76))
                    )

                Group {
                    switch store.phase {
                    case .memo:         memoEditor
                    case .savingMemo:   savingProgress
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MochiTheme.Spacing.l)

                Spacer(minLength: MochiTheme.Spacing.m)

                if store.phase == .memo {
                    Button("취소") { store.send(.dismissTapped) }
                        .font(MochiTheme.Typography.body)
                        .foregroundStyle(MochiTheme.Palette.textSecondary)
                        .padding(.bottom, MochiTheme.Spacing.l)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.phase)
    }

    // MARK: - phase contents

    private var memoEditor: some View {
        VStack(spacing: MochiTheme.Spacing.m) {
            Text("간단한 기록")
                .font(MochiTheme.Typography.headline)
                .foregroundStyle(MochiTheme.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $store.memoText.sending(\.memoTextChanged))
                .font(MochiTheme.Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 200)
                .padding(MochiTheme.Spacing.s)
                .background(MochiTheme.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: MochiTheme.Radius.m))

            Button { store.send(.memoSaveTapped) } label: {
                Text("저장")
                    .font(MochiTheme.Typography.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MochiTheme.Spacing.m)
                    .background(saveDisabled
                                ? MochiTheme.Palette.textSecondary.opacity(0.4)
                                : MochiTheme.Palette.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: MochiTheme.Radius.m))
            }
            .disabled(saveDisabled)
        }
    }

    private var savingProgress: some View {
        VStack(spacing: MochiTheme.Spacing.s) {
            ProgressView()
            Text("저장 중…")
                .font(MochiTheme.Typography.body)
                .foregroundStyle(MochiTheme.Palette.textSecondary)
        }
    }

    // MARK: - Helpers

    private var saveDisabled: Bool {
        store.memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
