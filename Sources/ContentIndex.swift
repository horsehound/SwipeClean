// What's in each photo, found on the phone with Apple's Vision framework:
// - things and scenes ("dog", "beach", "food", "sunset") for every photo,
// - text, for screenshots and photos that look like documents, receipts, signs and so on.
// Nothing leaves the phone. Results are saved, so each photo is only looked at once.

import SwiftUI
import Photos
import Vision

/// What the phone recognised in one photo.
struct PhotoContent: Codable {
    var labels: [String]   // Vision's names, e.g. "dog", "sunset_sunrise"
    var text: String?      // text read from the photo, folded for searching
}

@MainActor
final class ContentIndex: ObservableObject {
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private var entries: [String: PhotoContent] = [:]   // photo id -> content
    private var byLabel: [String: Set<String>] = [:]    // label -> photo ids
    private var texts: [String: String] = [:]           // photo id -> folded text
    private var cacheLoaded = false
    private var task: Task<Void, Never>?

    var isWorking: Bool { done < total }

    /// Looks at every photo that hasn't been looked at yet, newest first.
    func start(months: [Month], screenshots: Set<String>) {
        if !cacheLoaded { loadCache() }
        var pending: [PHAsset] = []
        var count = 0
        for month in months {
            for (asset, id) in zip(month.assets, month.ids) {
                count += 1
                if entries[id] == nil { pending.append(asset) }
            }
        }
        total = count
        done = count - pending.count

        task?.cancel()
        guard !pending.isEmpty else { return }
        task = Task { await scan(pending, screenshots: screenshots) }
    }

    // MARK: Searching

    /// Photos showing something whose name starts with the word, or with the word in their text.
    func photos(matching token: String) -> Set<String> {
        var ids = Set<String>()
        guard token.count >= 3 else { return ids }
        let translated = ContentWords.labels(for: token)
        for (label, labelIDs) in byLabel where translated.contains(label) || Self.label(label, startsWith: token) {
            ids.formUnion(labelIDs)
        }
        for (id, text) in texts where text.contains(token) {
            ids.insert(id)
        }
        return ids
    }

    /// Things that match what's typed, most photos first.
    func suggestions(for typed: String, limit: Int = 4) -> [String] {
        guard typed.count >= 3 else { return [] }
        let translated = ContentWords.labels(for: typed)
        return byLabel
            .filter { translated.contains($0.key) || Self.label($0.key, startsWith: typed) }
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .map { $0.key.replacingOccurrences(of: "_", with: " ") }
    }

    private static func label(_ label: String, startsWith token: String) -> Bool {
        label.split(separator: "_").contains { $0.hasPrefix(token) }
    }

    // MARK: Looking at photos

    private func scan(_ assets: [PHAsset], screenshots: Set<String>) async {
        var unsaved = 0
        defer {
            saveCache()
            publishProgress()
        }
        for asset in assets {
            if Task.isCancelled { return }
            let id = asset.localIdentifier
            let content = await Self.analyse(asset, readText: screenshots.contains(id))
            processed += 1
            if let content {
                add(content, for: id)
                unsaved += 1
            }
            if processed % 20 == 0 { publishProgress() }
            if unsaved >= 100 {
                saveCache()
                unsaved = 0
            }
        }
    }

    private var processed = 0

    private func publishProgress() {
        done = min(total, done + processed)
        processed = 0
    }

    private func add(_ content: PhotoContent, for id: String) {
        entries[id] = content
        for label in content.labels { byLabel[label, default: []].insert(id) }
        if let text = content.text { texts[id] = text }
    }

    /// Vision labels that suggest there's text worth reading.
    private nonisolated static let textLabels: Set<String> = [
        "document", "text", "receipt", "sign", "signboard", "poster", "menu", "book", "paper",
        "handwriting", "whiteboard", "blackboard", "screenshot", "newspaper", "magazine", "label",
        "banner", "billboard", "ticket", "letter", "card", "note",
    ]

    private nonisolated static func analyse(_ asset: PHAsset, readText: Bool) async -> PhotoContent? {
        guard let small = await image(asset, side: 360) else { return nil }
        let labels = classify(small)
        var text: String?
        if readText || labels.contains(where: { textLabels.contains($0) }),
           let large = await image(asset, side: 1400) {
            text = read(large)
        }
        return PhotoContent(labels: labels, text: text)
    }

    private nonisolated static func image(_ asset: PHAsset, side: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat   // one callback, at the size asked for
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true        // photos kept in iCloud
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    private nonisolated static func classify(_ image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.3 }
            .map(\.identifier)
    }

    private nonisolated static func read(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: " ").folded.prefix(2000))
    }

    // MARK: Saving

    private static var cacheURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("content.json")
    }

    private func loadCache() {
        cacheLoaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let saved = try? JSONDecoder().decode([String: PhotoContent].self, from: data)
        else { return }
        for (id, content) in saved { add(content, for: id) }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

/// German words for common things, mapped to Vision's English names.
enum ContentWords {
    private static let german: [String: [String]] = [
        "hund": ["dog"], "hunde": ["dog"], "katze": ["cat"], "katzen": ["cat"], "pferd": ["horse"],
        "vogel": ["bird"], "tier": ["animal"], "tiere": ["animal"], "fisch": ["fish"],
        "strand": ["beach"], "meer": ["ocean", "sea"], "see": ["lake"], "berg": ["mountain"], "berge": ["mountain"],
        "wald": ["forest"], "baum": ["tree"], "baume": ["tree"], "blume": ["flower"], "blumen": ["flower"],
        "himmel": ["sky"], "wolke": ["cloudy"], "wolken": ["cloudy"], "schnee": ["snow"], "eis": ["ice"],
        "sonnenuntergang": ["sunset_sunrise"], "sonnenaufgang": ["sunset_sunrise"], "nacht": ["night_sky"],
        "essen": ["food"], "kuchen": ["cake"], "torte": ["cake"], "brot": ["bread"], "obst": ["fruit"],
        "gemuse": ["vegetable"], "getrank": ["beverage", "drink"], "kaffee": ["coffee"], "bier": ["beer"], "wein": ["wine"],
        "auto": ["car", "automobile"], "fahrrad": ["bicycle"], "motorrad": ["motorcycle"], "flugzeug": ["airplane", "aircraft"],
        "zug": ["train"], "boot": ["boat"], "schiff": ["ship", "boat"], "bus": ["bus"],
        "haus": ["house", "building"], "gebaude": ["building"], "kirche": ["church"], "brucke": ["bridge"],
        "stadt": ["city", "cityscape"], "strasse": ["street", "road"], "straße": ["street", "road"],
        "menschen": ["people"], "leute": ["people"], "person": ["people", "adult"], "kind": ["child"], "kinder": ["child"],
        "konzert": ["concert"], "geburtstag": ["birthday_cake"], "hochzeit": ["wedding"], "feuerwerk": ["fireworks"],
        "weihnachten": ["christmas_tree"], "dokument": ["document"], "quittung": ["receipt"], "kassenbon": ["receipt"],
        "rechnung": ["receipt", "document"], "buch": ["book"], "spielzeug": ["toy"], "handy": ["cellphone"],
        "tisch": ["table"], "fenster": ["window"], "garten": ["garden"], "wasser": ["water"], "schwimmbad": ["swimming_pool"],
        "kleidung": ["clothing"], "schuhe": ["shoes"], "spiegel": ["mirror"], "bett": ["bed"], "kuche": ["kitchen"],
    ]

    /// Vision names for a German word (or the start of one).
    static func labels(for token: String) -> Set<String> {
        guard token.count >= 3 else { return [] }
        return Set(german.filter { $0.key.hasPrefix(token) }.flatMap(\.value))
    }
}
