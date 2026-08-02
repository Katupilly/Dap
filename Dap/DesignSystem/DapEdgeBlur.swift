import SwiftUI
import UIKit

public struct DapEdgeBlur: UIViewRepresentable {
    public enum Edge: Equatable {
        case top
        case bottom
    }

    public let edge: Edge

    public init(edge: Edge) {
        self.edge = edge
    }

    public func makeUIView(context: Context) -> UIView {
        DapEdgeBlurView(edge: edge)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let blurView = uiView as? DapEdgeBlurView else { return }
        blurView.update(edge: edge)
    }
}

private final class DapEdgeBlurView: UIView {
    private var edge: DapEdgeBlur.Edge
    private let maskLayer = CAGradientLayer()
    private let blurView = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemMaterial)
    )

    init(edge: DapEdgeBlur.Edge) {
        self.edge = edge
        super.init(frame: .zero)

        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
        layer.mask = maskLayer

        blurView.isOpaque = false
        blurView.isUserInteractionEnabled = false
        blurView.clipsToBounds = true
        blurView.backgroundColor = .clear
        blurView.contentView.isOpaque = false
        blurView.contentView.isUserInteractionEnabled = false
        blurView.contentView.backgroundColor = .clear
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        maskLayer.frame = bounds
        updateMask()
    }

    func update(edge: DapEdgeBlur.Edge) {
        guard self.edge != edge else { return }
        self.edge = edge
        updateMask()
    }

    private func updateMask() {
        let stops: [(location: CGFloat, alpha: CGFloat)]

        switch edge {
        case .top:
            stops = [
                (0.00, 1.00),
                (0.30, 0.92),
                (0.58, 0.55),
                (0.82, 0.16),
                (1.00, 0.00),
            ]
        case .bottom:
            stops = [
                (0.00, 0.00),
                (0.18, 0.16),
                (0.42, 0.55),
                (0.70, 0.92),
                (1.00, 1.00),
            ]
        }

        maskLayer.colors = stops.map { CGColor(gray: 1, alpha: $0.alpha) }
        maskLayer.locations = stops.map { NSNumber(value: Double($0.location)) }
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1)
    }
}
