// FixedRatioBox(Layout) 의미론 검증 — DetailView.swift 의 구현과 동일한 코드.
// (358,nil)/(nil,nil)/(358,150) 제안 모두에서 박스가 이미지·자식 크기와 무관하게 잡히는지.
import SwiftUI
import AppKit

struct FixedRatioBox: Layout {
    let ratio: CGFloat
    let fallbackWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = proposal.width ?? fallbackWidth
        if !width.isFinite { width = fallbackWidth }
        return CGSize(width: width, height: width / ratio)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

struct MeasureLayout: Layout {
    let tag: String
    let p: ProposedViewSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews[0].sizeThatFits(p)
        print("\(tag): \(s.width) x \(s.height)")
        return s
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: p)
    }
}

// 작은 이미지(205×154)를 흉내내는 representable — sizeThatFits 미구현(최악 케이스).
struct SmallImageView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(); v.image = NSImage(size: .init(width: 205, height: 154)); return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {}
}

struct Probe: View {
    var body: some View {
        VStack {
            MeasureLayout(tag: "scrollview(358,nil)", p: .init(width: 358, height: nil)) {
                FixedRatioBox(ratio: 4.0/3.0, fallbackWidth: 320) { SmallImageView() }
            }
            MeasureLayout(tag: "ideal(nil,nil)", p: .init(width: nil, height: nil)) {
                FixedRatioBox(ratio: 4.0/3.0, fallbackWidth: 320) { SmallImageView() }
            }
            MeasureLayout(tag: "constrained(358,150)", p: .init(width: 358, height: 150)) {
                FixedRatioBox(ratio: 4.0/3.0, fallbackWidth: 320) { SmallImageView() }
            }
        }
    }
}

let hosting = NSHostingView(rootView: Probe())
hosting.setFrameSize(NSSize(width: 390, height: 844))
hosting.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
