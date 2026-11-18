import Foundation
import CuvenCore

// MARK: - Canonical 14 Cuven Telegram Sticker Pack Presets (M10)
//
// Grounded directly in `src/stickers.js:35-50` & `public/js/views/stickers.js:35-43`:
// All 14 curated Telegram sticker packs (`HandDrawnEmoji`, `GameEmoji`, `ParisOlympicEmoji`,
// `UtyaDuck`, `HotCherry`, `AnimatedEmojies`, `LadyCat`, `MottyEmojiAnim`, `SiameseCatLive`,
// `LINE_Mochi_Mochi_Peach_Cat`, `CAT_CAT_CAT111`, `Pusheen_3`, `utya_vk`, `AngryDuck`) across
// static WebP (`.staticWebP`), animated Lottie JSON (`.animatedLottie`), and looping video (`.videoWebM`).

public struct StickerPackCatalogDescriptor: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let format: StickerFormat
    public let defaultEmojis: [String]

    public init(name: String, title: String, format: StickerFormat, defaultEmojis: [String]) {
        self.name = name
        self.title = title
        self.format = format
        self.defaultEmojis = defaultEmojis
    }
}

public enum CuvenStickerCatalogRegistry {
    /// Exact 14 preset packs from `src/stickers.js:35-50` (`PRESETS`).
    public static let presets: [StickerPackCatalogDescriptor] = [
        StickerPackCatalogDescriptor(
            name: "HandDrawnEmoji",
            title: "Hand-drawn",
            format: .staticWebP,
            defaultEmojis: ["😊", "😂", "🥰", "😎", "🤔", "🙌", "✨", "🔥", "🎉", "🫡", "🥹", "❤️"]
        ),
        StickerPackCatalogDescriptor(
            name: "GameEmoji",
            title: "Games",
            format: .animatedLottie,
            defaultEmojis: ["🎮", "🕹️", "🏆", "🎲", "🎯", "👾", "🚀", "⚡", "💎", "🛡️", "⚔️", "🌟"]
        ),
        StickerPackCatalogDescriptor(
            name: "ParisOlympicEmoji",
            title: "Paris Olympics",
            format: .animatedLottie,
            defaultEmojis: ["🥇", "🏃", "🏊", "🚴", "🤸", "🎾", "🏀", "⚽", "🥐", "🗼", "🔥", "🏅"]
        ),
        StickerPackCatalogDescriptor(
            name: "UtyaDuck",
            title: "Little Duck",
            format: .animatedLottie,
            defaultEmojis: ["🐤", "💛", "🥳", "😴", "😭", "🤩", "☕", "💻", "🫶", "👀", "🍕", "🎵"]
        ),
        StickerPackCatalogDescriptor(
            name: "HotCherry",
            title: "Hot Cherry",
            format: .animatedLottie,
            defaultEmojis: ["🍒", "💃", "😘", "🤭", "😡", "💅", "🌸", "🍓", "💌", "🙈", "✨", "🥂"]
        ),
        StickerPackCatalogDescriptor(
            name: "AnimatedEmojies",
            title: "Animated Emoji",
            format: .animatedLottie,
            defaultEmojis: ["😀", "🤣", "😍", "🤯", "🥳", "😇", "🤗", "😴", "🥶", "😱", "👍", "❤️‍🔥"]
        ),
        StickerPackCatalogDescriptor(
            name: "LadyCat",
            title: "Lady Cat",
            format: .staticWebP,
            defaultEmojis: ["🐱", "🎀", "😻", "😿", "😼", "🐾", "🍵", "🌷", "💤", "🧶", "🍰", "💖"]
        ),
        StickerPackCatalogDescriptor(
            name: "MottyEmojiAnim",
            title: "Motty Cat",
            format: .animatedLottie,
            defaultEmojis: ["😺", "🍡", "😸", "🙀", "😽", "🐟", "🌙", "☁️", "🎈", "🍀", "🫧", "🤍"]
        ),
        StickerPackCatalogDescriptor(
            name: "SiameseCatLive",
            title: "Siamese Cat",
            format: .videoWebM,
            defaultEmojis: ["🐈", "🐾", "慵", "🐟", "🥛", "🛋️", "😺", "😾", "💤", "🧶", "🌞", "💙"]
        ),
        StickerPackCatalogDescriptor(
            name: "LINE_Mochi_Mochi_Peach_Cat",
            title: "Peach Cat",
            format: .videoWebM,
            defaultEmojis: ["🍑", "🐱", "🥰", "🤗", "😭", "😤", "🍰", "🧋", "🌸", "💞", "😴", "🎉"]
        ),
        StickerPackCatalogDescriptor(
            name: "CAT_CAT_CAT111",
            title: "Kiang Cat",
            format: .videoWebM,
            defaultEmojis: ["🐱", "🤪", "💃", "🕺", "🎸", "🕶️", "🍜", "⚡", "😂", "🙌", "🔥", "🎊"]
        ),
        StickerPackCatalogDescriptor(
            name: "Pusheen_3",
            title: "Pusheen",
            format: .staticWebP,
            defaultEmojis: ["🐱", "🍩", "🍕", "🍪", "🍦", "🍔", "🍟", "🧁", "😴", "💻", "📚", "✨"]
        ),
        StickerPackCatalogDescriptor(
            name: "utya_vk",
            title: "Utya Duck",
            format: .staticWebP,
            defaultEmojis: ["🦆", "👋", "👍", "😂", "❤️", "🎉", "☕", "😎", "🤔", "😢", "🙏", "🔥"]
        ),
        StickerPackCatalogDescriptor(
            name: "AngryDuck",
            title: "Angry Duck",
            format: .animatedLottie,
            defaultEmojis: ["🦆", "😠", "🤬", "😤", "💢", "🔥", "👀", "😒", "🫡", "💥", "🫠", "✌️"]
        )
    ]

    /// Merges server-loaded `store.stickerPacks` with the 14 canonical Cuven Telegram packs so the `+` Catalog
    /// and shelf always present all 14 curated packs even in offline/demo environments (`--uitest-demo`).
    public static func mergedCatalogPacks(
        storePacks: [StickerPack],
        serverBaseURL: URL
    ) -> [StickerPack] {
        var byLowerName: [String: StickerPack] = [:]
        for pack in storePacks where !pack.stickers.isEmpty {
            byLowerName[pack.name.lowercased()] = pack
        }

        var ordered: [StickerPack] = []
        // First preserve any store-provided packs in their exact order
        for pack in storePacks where !pack.stickers.isEmpty {
            if !ordered.contains(where: { $0.name.caseInsensitiveCompare(pack.name) == .orderedSame }) {
                ordered.append(pack)
            }
        }

        // Fill in any remaining packs from the 14 canonical presets
        for descriptor in presets {
            let key = descriptor.name.lowercased()
            if byLowerName[key] == nil {
                ordered.append(synthesizePack(from: descriptor, serverBaseURL: serverBaseURL))
            }
        }
        return ordered
    }

    /// Resolves installed packs in shelf order (matching `src/stickers.js` case-insensitive `sameSet`).
    public static func installedPacks(
        from allPacks: [StickerPack],
        installedNames: Set<String>
    ) -> [StickerPack] {
        let lowerInstalled = Set(installedNames.map { $0.lowercased() })
        let filtered = allPacks.filter { lowerInstalled.contains($0.name.lowercased()) }
        if !filtered.isEmpty {
            return filtered
        }
        // Default starting packs (`HandDrawnEmoji,GameEmoji` per `src/stickers.js:19`) when set is empty
        return Array(allPacks.prefix(2))
    }

    public static func isPackInstalled(_ packName: String, in installedNames: Set<String>) -> Bool {
        installedNames.contains { $0.caseInsensitiveCompare(packName) == .orderedSame }
    }

    /// Resolves relative `/api/stickers/...` paths against `AppStore.serverBaseURL`.
    public static func resolvedURL(_ rawURL: String, serverBaseURL: URL) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }
        if trimmed.hasPrefix("/") {
            var baseString = serverBaseURL.absoluteString
            if baseString.hasSuffix("/") {
                baseString.removeLast()
            }
            return URL(string: baseString + trimmed)
        }
        return URL(string: trimmed, relativeTo: serverBaseURL)?.absoluteURL
    }

    private static func synthesizePack(
        from descriptor: StickerPackCatalogDescriptor,
        serverBaseURL: URL
    ) -> StickerPack {
        var baseString = serverBaseURL.absoluteString
        if baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        let encodedSet = descriptor.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? descriptor.name

        let items: [StickerItem] = descriptor.defaultEmojis.enumerated().map { index, emoji in
            let stickerID = "\(descriptor.name)_\(String(format: "%02d", index + 1))"
            let thumb = "\(baseString)/api/stickers/img/\(stickerID)?set=\(encodedSet)&thumb=1"
            let asset: String
            switch descriptor.format {
            case .animatedLottie:
                asset = "\(baseString)/api/stickers/anim/\(stickerID)?set=\(encodedSet)"
            case .videoWebM, .staticWebP:
                asset = "\(baseString)/api/stickers/img/\(stickerID)?set=\(encodedSet)"
            }
            return StickerItem(
                id: stickerID,
                setName: descriptor.name,
                emoji: emoji,
                format: descriptor.format,
                thumbURL: thumb,
                assetURL: asset
            )
        }

        return StickerPack(
            name: descriptor.name,
            title: descriptor.title,
            format: descriptor.format,
            stickers: items
        )
    }
}
