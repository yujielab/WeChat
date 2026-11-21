import SwiftUI
import TipKit

// MARK: - Tips

/// Recording is hidden in a gesture: said once, in the system's own tip.
struct HoldToTalkTip: Tip {
    var title: Text { Text("Hold to record a voice message") }
    var message: Text? { Text("Touch and hold the empty message field. Let go to send, or slide up first to cancel.") }
    var image: Image? { Image(systemName: "waveform") }
    var options: [any TipOption] { [Tips.MaxDisplayCount(2)] }
}

enum CuvenTips {
    static func configure() {
        if Automation.active { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
