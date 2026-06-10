import ComposableArchitecture
import CoreNetworking
import DesignSystem
import SwiftUI

/// 지난 대화 시트 — 말풍선 아이콘 + 첫 질문 제목 + 상대 시각, 스와이프 삭제.
struct ChatHistoryView: View {
    let store: StoreOf<ChatHistoryFeature>

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("지난 대화")
                .navigationBarTitleDisplayMode(.inline)
                .background(HomeDesign.Color.bg.ignoresSafeArea())
        }
        .task { store.send(.task) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.conversations.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.conversations.isEmpty {
            emptyState
        } else {
            List {
                ForEach(store.conversations) { conversation in
                    row(conversation)
                        .listRowBackground(HomeDesign.Color.bg)
                        .listRowSeparatorTint(HomeDesign.Color.border.opacity(0.6))
                }
                .onDelete { offsets in
                    for offset in offsets {
                        store.send(
                            .deleteSwiped(store.conversations[offset].id),
                            animation: .spring(response: 0.35, dampingFraction: 0.85)
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ conversation: ChatConversationDTO) -> some View {
        Button {
            store.send(.conversationTapped(conversation.id))
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(HomeDesign.Color.purple100.opacity(0.55)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title?.isEmpty == false ? conversation.title! : "새 대화")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                    Text(Self.relative(conversation.updatedAt))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(HomeDesign.Color.textFaint)
            Text("아직 나눈 대화가 없어요")
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
            Text("모찌에게 무엇이든 물어보세요")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
