// aspectRatio + nil 높이 제안(ScrollView) 레이아웃 의미론 검증.
// DetailView RecallHeader 의 이미지 박스가 ScrollView 안에서 어떤 크기로 풀리는지 측정.
import SwiftUI
import AppKit

final class SizeBox { var sizes: [String: CGSize] = [:] }
let sizeBox = SizeBox()

struct Reporter: View {
    let tag: String
    var body: some View {
        GeometryReader { g -> Color in
            DispatchQueue.main.async { sizeBox.sizes[tag] = g.size }
            return Color.clear
        }
    }
}

// NSImageView 기반 representable — iOS 쪽 UIKitImageView 의 macOS 등가물.
struct RepImageView: NSViewRepresentable {
    let imageSize: CGSize
    let overrideSizeThatFits: Bool
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        let img = NSImage(size: imageSize)
        img.lockFocus(); NSColor.red.setFill(); NSRect(origin: .zero, size: imageSize).fill(); img.unlockFocus()
        v.image = img
        v.imageScaling = .scaleAxesIndependently
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        overrideSizeThatFits ? proposal.replacingUnspecifiedDimensions() : nil
    }
}

struct Probe: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // A) 작업트리 패턴: Color.clear.aspectRatio + overlay
                Color.clear
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay { Reporter(tag: "A-overlay") }
                    .background(Reporter(tag: "A-box"))
                    .frame(maxWidth: .infinity)

                // B) HEAD 패턴: representable(.frame max ∞) + 바깥 aspectRatio — 작은 이미지(205×154)
                RepImageView(imageSize: CGSize(width: 205, height: 154), overrideSizeThatFits: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .background(Reporter(tag: "B-small"))
                    .frame(maxWidth: .infinity)

                // C) HEAD 패턴 — 큰 이미지(443×960)
                RepImageView(imageSize: CGSize(width: 443, height: 960), overrideSizeThatFits: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .background(Reporter(tag: "C-big"))
                    .frame(maxWidth: .infinity)

                // D) 작업트리 패턴 전체: Color.clear.aspectRatio + overlay(representable, sizeThatFits override)
                Color.clear
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay { RepImageView(imageSize: CGSize(width: 205, height: 154), overrideSizeThatFits: true) }
                    .clipped()
                    .background(Reporter(tag: "D-full"))
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .frame(width: 390, height: 844)
    }
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 844),
                      styleMask: [.titled], backing: .buffered, defer: false)
let hosting = NSHostingView(rootView: Probe())
hosting.frame = window.contentView!.bounds
window.contentView!.addSubview(hosting)
hosting.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
for (k, v) in sizeBox.sizes.sorted(by: { $0.key < $1.key }) {
    print("\(k): \(Int(v.width))x\(Int(v.height))")
}
