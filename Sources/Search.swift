// Search and filters for SwipeClean, modelled on the search in the Photos app:
// - photo types (favourites, screenshots, selfies, …) come from Photos' own smart albums,
// - months and years ("march", "2023", "märz 2021") come from the photo dates,
// - places ("Berlin", a district, a street, a country) come from each photo's location,
//   which is turned into a place name on the phone and saved, so it only happens once.

import SwiftUI
import Photos
import CoreLocation

extension String {
    /// Lowercased and without accents, for matching ("Köln" -> "koln").
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }
}

// MARK: - Filters

enum PhotoFilter: String, CaseIterable, Identifiable, Hashable {
    case favorites, screenshots, selfies, livePhotos, portraits, panoramas, bursts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Favourites"
        case .screenshots: return "Screenshots"
        case .selfies: return "Selfies"
        case .livePhotos: return "Live Photos"
        case .portraits: return "Portraits"
        case .panoramas: return "Panoramas"
        case .bursts: return "Bursts"
        }
    }

    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .screenshots: return "camera.viewfinder"
        case .selfies: return "person.crop.square"
        case .livePhotos: return "livephoto"
        case .portraits: return "cube"
        case .panoramas: return "pano"
        case .bursts: return "square.stack.3d.down.right"
        }
    }

    /// Words you can type to get this filter (English and German, already folded).
    private var words: [String] {
        switch self {
        case .favorites: return ["favourites", "favorites", "favourite", "favorite", "favoriten", "favorit"]
        case .screenshots: return ["screenshots", "screenshot", "bildschirmfotos", "bildschirmfoto"]
        case .selfies: return ["selfies", "selfie"]
        case .livePhotos: return ["livephotos", "livephoto", "live"]
        case .portraits: return ["portraits", "portrait", "portrats", "portrat", "portraets", "portraet"]
        case .panoramas: return ["panoramas", "panorama", "pano"]
        case .bursts: return ["bursts", "burst", "serienbilder", "serienbild"]
        }
    }

    func matches(word token: String) -> Bool {
        token.count >= 3 && words.contains { $0.hasPrefix(token) }
    }

    private var smartAlbum: PHAssetCollectionSubtype? {
        switch self {
        case .favorites: return nil   // read straight from each photo, so toggling shows up at once
        case .screenshots: return .smartAlbumScreenshots
        case .selfies: return .smartAlbumSelfPortraits
        case .livePhotos: return .smartAlbumLivePhotos
        case .portraits: return .smartAlbumDepthEffect
        case .panoramas: return .smartAlbumPanoramas
        case .bursts: return .smartAlbumBursts
        }
    }

    /// The photo ids in each of Photos' smart albums.
    static func loadSmartAlbums() -> [PhotoFilter: Set<String>] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var result: [PhotoFilter: Set<String>] = [:]
        for filter in allCases {
            guard let subtype = filter.smartAlbum,
                  let album = PHAssetCollection.fetchAssetCollections(
                      with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { continue }
            var ids = Set<String>()
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
            result[filter] = ids
        }
        return result
    }
}

// MARK: - Query

struct SearchQuery: Hashable {
    var text = ""
    var filters: Set<PhotoFilter> = []

    /// Words that don't narrow anything down ("photos from berlin" = "berlin").
    private static let fillers: Set<String> = [
        "photo", "photos", "foto", "fotos", "picture", "pictures", "pic", "pics", "bild", "bilder",
        "from", "in", "at", "of", "the", "von", "aus", "im", "am", "der", "die", "das",
    ]

    var tokens: [String] {
        text.folded
            .split { $0.isWhitespace || $0 == "," }
            .map(String.init)
            .filter { !Self.fillers.contains($0) }
    }

    var isEmpty: Bool { tokens.isEmpty && filters.isEmpty }

    var title: String {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let names = PhotoFilter.allCases.filter { filters.contains($0) }.map(\.title)
        return ([typed].filter { !$0.isEmpty } + names).joined(separator: " · ")
    }
}

/// What a swipe deck goes through: one month, or the results of a search.
enum DeckSource: Hashable {
    case month(Int)
    case search(SearchQuery)
}

/// Month names in the phone's language, English and German, folded ("märz" -> 3).
private enum MonthWords {
    static let numbers: [String: Int] = {
        var map: [String: Int] = [:]
        for identifier in [Locale.current.identifier, "en_US", "de_DE"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: identifier)
            let lists = [calendar.monthSymbols, calendar.shortMonthSymbols,
                         calendar.standaloneMonthSymbols, calendar.shortStandaloneMonthSymbols]
            for list in lists {
                for (index, name) in list.enumerated() {
                    map[name.folded.replacingOccurrences(of: ".", with: "")] = index + 1
                }
            }
        }
        return map
    }()
}

/// One typed word, and everything it could mean.
private struct SearchTerm {
    let year: Int?
    let month: Int?
    let filters: [PhotoFilter]
    let cells: Set<String>   // places whose name contains the word

    @MainActor
    init(_ token: String, places: PlaceIndex) {
        if token.count == 4, let number = Int(token), (1900...2100).contains(number) {
            year = number
        } else {
            year = nil
        }
        month = MonthWords.numbers[token]
        filters = PhotoFilter.allCases.filter { $0.matches(word: token) }
        cells = places.cells(matching: token)
    }
}

// MARK: - Searching the library

extension PhotoStore {
    func isReviewed(_ id: String) -> Bool { kept.contains(id) || trashIDs.contains(id) }
    func isTrashed(_ id: String) -> Bool { trashIDs.contains(id) }

    func has(_ filter: PhotoFilter, _ asset: PHAsset) -> Bool {
        if filter == .favorites { return isFavorite(asset) }
        return filterIDs[filter]?.contains(asset.localIdentifier) ?? false
    }

    /// Every photo that fits the query, newest first. Each typed word has to fit
    /// (as a year, a month, a photo type or a place), and so does every chosen filter.
    func search(_ query: SearchQuery, places: PlaceIndex) -> [PHAsset] {
        let terms = query.tokens.map { SearchTerm($0, places: places) }
        var results: [PHAsset] = []
        for month in months {
            let year = month.id / 100
            let monthNumber = month.id % 100
            for (asset, id) in zip(month.assets, month.ids) {
                guard query.filters.allSatisfy({ has($0, asset) }) else { continue }
                let cell = places.cell(of: id)
                let matched = terms.allSatisfy { term in
                    fits(term, asset: asset, year: year, month: monthNumber, cell: cell)
                }
                if matched { results.append(asset) }
            }
        }
        return results
    }

    private func fits(_ term: SearchTerm, asset: PHAsset, year: Int, month: Int, cell: String?) -> Bool {
        if let wanted = term.year, wanted == year { return true }
        if let wanted = term.month, wanted == month { return true }
        if term.filters.contains(where: { has($0, asset) }) { return true }
        if let cell, term.cells.contains(cell) { return true }
        return false
    }

    // MARK: Decks

    func assets(for source: DeckSource, places: PlaceIndex) -> [PHAsset] {
        switch source {
        case .month(let id): return month(id)?.assets ?? []
        case .search(let query): return search(query, places: places)
        }
    }

    func unreviewed(_ source: DeckSource, places: PlaceIndex) -> [PHAsset] {
        assets(for: source, places: places).filter { !isReviewed($0.localIdentifier) }
    }

    /// Lets you go through these photos again. Photos already in the trash stay there.
    func reviewAgain(_ source: DeckSource, places: PlaceIndex) {
        unkeep(assets(for: source, places: places).map(\.localIdentifier))
    }

    func title(for source: DeckSource) -> String {
        switch source {
        case .month(let id): return month(id)?.title ?? "SwipeClean"
        case .search(let query): return query.title
        }
    }
}

// MARK: - Places

/// A place name for a spot on the map, as returned by Apple's geocoder.
struct Place: Codable, Hashable {
    var name: String?
    var street: String?
    var district: String?
    var city: String?
    var area: String?
    var country: String?

    /// The name shown on a chip: the city if there is one.
    var label: String? { city ?? district ?? area ?? country }

    var names: Set<String> { Set([city, district, street, area, country].compactMap { $0 }) }

    var searchText: String {
        [name, street, district, city, area, country].compactMap { $0 }.joined(separator: " ").folded
    }
}

extension Place {
    init(_ mark: CLPlacemark?) {
        name = mark?.name
        street = mark?.thoroughfare
        district = mark?.subLocality
        city = mark?.locality
        area = mark?.administrativeArea
        country = mark?.country
    }
}

/// Turns photo locations into place names and remembers them.
/// Photos are grouped into small map squares (a few hundred metres across), and each
/// square is looked up once, busiest first. Apple limits how fast apps may look places
/// up, so a big library takes a while the first time; progress is saved as it goes and
/// carries on at the next launch.
@MainActor
final class PlaceIndex: ObservableObject {
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private var places: [String: Place] = [:]       // square -> place
    private var texts: [String: String] = [:]       // square -> folded text to search
    private var squareOf: [String: String] = [:]    // photo id -> square
    private var photosPerSquare: [String: Int] = [:]
    private var cacheLoaded = false
    private var task: Task<Void, Never>?

    var isWorking: Bool { done < total }

    func start(months: [Month]) {
        if !cacheLoaded { loadCache() }

        var squareOf: [String: String] = [:]
        var counts: [String: Int] = [:]
        var spots: [String: CLLocation] = [:]
        for month in months {
            for (asset, id) in zip(month.assets, month.ids) {
                guard let location = asset.location else { continue }
                let square = Self.square(location.coordinate)
                squareOf[id] = square
                counts[square, default: 0] += 1
                if spots[square] == nil { spots[square] = location }
            }
        }
        self.squareOf = squareOf
        photosPerSquare = counts

        let pending = counts.keys
            .filter { places[$0] == nil }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
        total = counts.count
        done = total - pending.count

        task?.cancel()
        guard !pending.isEmpty else { return }
        task = Task { await lookUp(pending, spots: spots) }
    }

    func cell(of photoID: String) -> String? { squareOf[photoID] }

    func cells(matching token: String) -> Set<String> {
        Set(texts.compactMap { square, text in text.contains(token) ? square : nil })
    }

    /// The places with the most photos, for the chips.
    func topPlaces(_ limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for (square, count) in photosPerSquare {
            if let label = places[square]?.label { counts[label, default: 0] += count }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Place names containing what's typed, most photos first.
    func suggestions(for typed: String, limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:]
        for (square, count) in photosPerSquare {
            guard let place = places[square] else { continue }
            for name in place.names where name.folded.contains(typed) {
                counts[name, default: 0] += count
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: Looking places up

    private static func square(_ coordinate: CLLocationCoordinate2D) -> String {
        let size = 0.003   // degrees, roughly 300 m north–south
        return "\(Int((coordinate.latitude / size).rounded())):\(Int((coordinate.longitude / size).rounded()))"
    }

    private func lookUp(_ pending: [String], spots: [String: CLLocation]) async {
        let geocoder = CLGeocoder()
        var unsaved = 0
        defer { saveCache() }

        for square in pending {
            guard let location = spots[square] else { continue }
            var place: Place?
            var failures = 0
            while place == nil {
                if Task.isCancelled { return }
                do {
                    let marks = try await geocoder.reverseGeocodeLocation(location)
                    place = Place(marks.first)
                } catch let error as CLError where error.code == .network {
                    // Offline, or Apple is asking us to slow down: wait, then try again.
                    failures += 1
                    if failures >= 3 { return }   // carry on at the next launch
                    try? await Task.sleep(for: .seconds(60))
                } catch {
                    place = Place()   // nothing known here, don't ask again
                }
            }
            guard let place else { continue }
            places[square] = place
            texts[square] = place.searchText
            done += 1
            unsaved += 1
            if unsaved >= 25 {
                saveCache()
                unsaved = 0
            }
            try? await Task.sleep(for: .seconds(1.2))
        }
    }

    // MARK: Saving

    private static var cacheURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("places.json")
    }

    private func loadCache() {
        cacheLoaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let saved = try? JSONDecoder().decode([String: Place].self, from: data)
        else { return }
        places = saved
        texts = saved.mapValues(\.searchText)
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

// MARK: - Views

struct FilterChips: View {
    @Binding var filters: Set<PhotoFilter>
    @Binding var text: String
    let places: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoFilter.allCases) { filter in
                    chip(filter.title, icon: filter.icon, on: filters.contains(filter)) {
                        if filters.contains(filter) {
                            filters.remove(filter)
                        } else {
                            filters.insert(filter)
                        }
                    }
                }
                ForEach(places, id: \.self) { place in
                    let on = text.folded.trimmingCharacters(in: .whitespaces) == place.folded
                    chip(place, icon: "mappin.and.ellipse", on: on) {
                        text = on ? "" : place
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func chip(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SearchResultsView: View {
    @ObservedObject var store: PhotoStore
    @ObservedObject var places: PlaceIndex
    let query: SearchQuery

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 2)]

    var body: some View {
        let results = store.search(query, places: places)
        let open = results.filter { !store.isReviewed($0.localIdentifier) }.count

        ScrollView {
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Text(results.count == 1 ? "1 photo" : "\(results.count) photos").font(.headline)
                        Text("· \(open) not reviewed").foregroundStyle(.secondary)
                    }
                    placesProgress
                    NavigationLink(value: DeckSource.search(query)) {
                        Text(open > 0 ? "Swipe through \(open)" : "All reviewed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(results, id: \.localIdentifier) { asset in
                        thumbnail(asset)
                    }
                }
            }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No photos", systemImage: "magnifyingglass")
                } description: {
                    if places.isWorking {
                        Text("Still finding places (\(places.done) of \(places.total)). Try again in a bit.")
                    } else {
                        Text("Try a place, a month, a year or a photo type.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var placesProgress: some View {
        if places.isWorking {
            Label("Finding places… \(places.done) of \(places.total)", systemImage: "mappin.and.ellipse")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func thumbnail(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let trashed = store.isTrashed(id)
        let reviewed = store.isReviewed(id)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetImage(asset: asset, side: 250, fill: true) }
            .clipped()
            .opacity(reviewed ? 0.45 : 1)
            .overlay(alignment: .bottomTrailing) {
                if reviewed {
                    Image(systemName: trashed ? "trash.circle.fill" : "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, trashed ? Color.red : Color.green)
                        .padding(4)
                }
            }
    }
}
