import SwiftUI

/// 앱 부팅 직후 노출되는 스플래시 화면.
/// `UILaunchScreen` 은 빈 dict 라서 시스템은 흰 화면만 잠깐 보여주고,
/// 실제 브랜딩은 이 SwiftUI 뷰에서 책임진다.
struct SplashView: View {
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            sparkles
                .allowsHitTesting(false)

            content
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
                .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.45),
                .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Content

    private var content: some View {
        GeometryReader { proxy in
            VStack(spacing: 16) {
                Spacer().frame(height: proxy.size.height * 0.12)

                Text("모찌")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(Self.titleColor)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 8)

                VStack(spacing: 4) {
                    Text("뭐든지 찍어보세요.")
                    Text("모찌가 기억하고 정리해드릴게요.")
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.subtitleColor)
                .multilineTextAlignment(.center)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 6)

                Spacer()

                Image("SplashMochi")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(proxy.size.width * 0.62, 280))
                    .scaleEffect(hasAppeared ? 1.0 : 0.92)
                    .opacity(hasAppeared ? 1 : 0)

                Spacer().frame(height: proxy.size.height * 0.14)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sparkles

    private var sparkles: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Self.sparkleSpecs, id: \.id) { spec in
                    SparkleShape()
                        .fill(Self.sparkleColor.opacity(spec.opacity))
                        .frame(width: spec.size, height: spec.size)
                        .position(
                            x: proxy.size.width * spec.x,
                            y: proxy.size.height * spec.y
                        )
                }
            }
        }
    }

    // MARK: - Tokens

    private static let titleColor = Color(red: 0.21, green: 0.20, blue: 0.45)
    private static let subtitleColor = Color(red: 0.36, green: 0.34, blue: 0.55)
    private static let sparkleColor = Color(red: 0.62, green: 0.58, blue: 0.85)

    private struct SparkleSpec {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
    }

    private static let sparkleSpecs: [SparkleSpec] = [
        .init(x: 0.12, y: 0.10, size: 10, opacity: 0.55),
        .init(x: 0.82, y: 0.08, size: 14, opacity: 0.45),
        .init(x: 0.20, y: 0.22, size: 7,  opacity: 0.40),
        .init(x: 0.70, y: 0.18, size: 9,  opacity: 0.50),
        .init(x: 0.88, y: 0.30, size: 12, opacity: 0.40),
        .init(x: 0.10, y: 0.40, size: 8,  opacity: 0.45),
        .init(x: 0.16, y: 0.58, size: 14, opacity: 0.55),
        .init(x: 0.84, y: 0.50, size: 10, opacity: 0.40),
        .init(x: 0.08, y: 0.74, size: 12, opacity: 0.50),
        .init(x: 0.90, y: 0.72, size: 9,  opacity: 0.45),
        .init(x: 0.24, y: 0.86, size: 11, opacity: 0.50),
        .init(x: 0.72, y: 0.90, size: 8,  opacity: 0.40),
        .init(x: 0.50, y: 0.94, size: 7,  opacity: 0.35),
    ]
}

/// 4각 별 형태의 반짝이. 가운데가 좁아지는 다이아몬드 + 90° 회전을 합성.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r  = min(rect.width, rect.height) / 2
        let inner = r * 0.28

        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addQuadCurve(
            to: CGPoint(x: cx + r, y: cy),
            control: CGPoint(x: cx + inner, y: cy - inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy + r),
            control: CGPoint(x: cx + inner, y: cy + inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - r, y: cy),
            control: CGPoint(x: cx - inner, y: cy + inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - r),
            control: CGPoint(x: cx - inner, y: cy - inner)
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    SplashView()
}
