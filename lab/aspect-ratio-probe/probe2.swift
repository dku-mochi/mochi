// 제안 (358, nil) — ScrollView 내 VStack 이 자식에 주는 제안 — 에 대한 각 패턴의 응답 크기를 직접 측정.
import SwiftUI
import AppKit

struct MeasureLayout: Layout {
    let tag: String
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = ProposedViewSize(width: 358, height: nil)
        let s = subviews[0].sizeThatFits(p)
        print("\(tag): \(s.width) x \(s.height)")
        return s
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: 358, height: nil))
    }
}

struct RepImageView: NSViewRepresentable {
    let imageSize: CGSize
    let overrideSizeThatFits: Bool
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        let img = NSImage(size: imageSize)
        v.image = img
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        overrideSizeThatFits ? proposal.replacingUnspecifiedDimensions() : nil
    }
}

struct Probe: View {
    var body: some View {
        VStack {
            MeasureLayout(tag: "A-colorclear-aspect") {
                Color.clear.aspectRatio(4.0/3.0, contentMode: .fit)
            }
            MeasureLayout(tag: "B-HEAD-small(205x154)") {
                RepImageView(imageSize: .init(width: 205, height: 154), overrideSizeThatFits: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
            }
            MeasureLayout(tag: "C-HEAD-big(443x960)") {
                RepImageView(imageSize: .init(width: 443, height: 960), overrideSizeThatFits: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
            }
            MeasureLayout(tag: "D-worktree-full") {
                Color.clear
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay { RepImageView(imageSize: .init(width: 205, height: 154), overrideSizeThatFits: true) }
                    .clipped()
            }
            MeasureLayout(tag: "E-rect-aspect") {
                Rectangle().aspectRatio(4.0/3.0, contentMode: .fit)
            }
        }
    }
}

let hosting = NSHostingView(rootView: Probe())
hosting.setFrameSize(NSSize(width: 390, height: 844))
hosting.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
