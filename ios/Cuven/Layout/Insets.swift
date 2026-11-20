import SwiftUI
import UIKit

/// The window's safe area, read from UIKit: the shell lays its columns out
/// itself (each column gets only the insets of the edges it touches), so it
/// ignores SwiftUI's safe area and needs the real numbers.
struct SafeAreaReader: UIViewRepresentable {
    var onChange: (EdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((EdgeInsets) -> Void)?
        private var last: UIEdgeInsets?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            let i = window?.safeAreaInsets ?? safeAreaInsets
            guard i != last else { return }
            last = i
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let e = EdgeInsets(top: i.top, leading: rtl ? i.right : i.left, bottom: i.bottom, trailing: rtl ? i.left : i.right)
            DispatchQueue.main.async { [weak self] in self?.onChange?(e) }
        }
    }
}

/// How much of the window the keyboard covers, animated with it.
@MainActor
@Observable
final class KeyboardObserver {
    var height: CGFloat = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.update(n) }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.update(n, hiding: true) }
        })
    }

    private func update(_ n: Notification, hiding: Bool = false) {
        let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.bounds ?? UIScreen.main.bounds
        let overlap = hiding ? 0 : max(0, screen.maxY - end.minY)
        guard abs(overlap - height) > 0.5 else { return }
        withAnimation(.spring(response: max(0.2, duration * 1.3), dampingFraction: 1)) {
            height = overlap
        }
    }
}
