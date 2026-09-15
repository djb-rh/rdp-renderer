import UIKit

/// Draws the faithful frame with the shared CoreGraphics renderer, 60 times a second.
final class RenderView: UIView {
    var world: World?
    var state: LinkState?
    var renderer = FrameRenderer()
    var packets: () -> Int = { 0 }
    private var link: CADisplayLink?
    var lastStats = RenderStats()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true; backgroundColor = .black; contentMode = .redraw
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tick() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let world = world, let state = state else { return }
        // render at the original aspect (8:3) letterboxed in the view; the projection keeps the original field of view
        let aspect: CGFloat = 512.0 / 192.0
        var r = bounds
        if r.width / r.height > aspect { r.size.width = r.height * aspect } else { r.size.height = r.width / aspect }
        r.origin = CGPoint(x: (bounds.width - r.width) / 2, y: (bounds.height - r.height) / 2)
        ctx.saveGState(); ctx.translateBy(x: r.origin.x, y: r.origin.y); ctx.clip(to: CGRect(origin: .zero, size: r.size))
        lastStats = renderer.draw(in: ctx, size: r.size, world: world, state: state)
        ctx.restoreGState()
    }
}
