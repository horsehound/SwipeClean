// SwipeClean – a tiny swipe-to-clean photo app.
// Pick a month, then swipe LEFT = mark for deletion, swipe RIGHT = keep,
// swipe UP = keep and add to your swipe-up album (remembered between launches).
// Nothing is deleted until you tap "Delete all" and confirm the iOS prompt.

import SwiftUI
import Photos
import UIKit

// MARK: - Model

struct Month: Identifiable {
    let id: Int            // year * 100 + month, 0 = photos without a date
    let title: String
    var assets: [PHAsset]
    var ids: [String]      // localIdentifiers, parallel to `assets`
}

enum SwipeAction {
    case keep, delete, file   // file = keep + add to the swipe-up album
}

/// Lets a Photos change block hand a value back out.
private final class Box: @unchecked Sendable {
    var value: String?
}

/// Where the swipe-up album choice is saved.
private enum AlbumDefaults {
    static let title = "SwipeClean"
    static let idKey = "swipeUpAlbumID"
    static let titleKey = "swipeUpAlbumTitle"
}

@MainActor
final class PhotoStore: ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var months: [Month] = []
    @Published var kept: Set<String> = []
    @Published var trash: [PHAsset] = []
    @Published var favorites: [String: Bool] = [:]   // local overrides after toggling
    @Published var deleteGeneration = 0              // bumps whenever photos were really deleted
    @Published var loaded = false
    @Published var filterIDs: [PhotoFilter: Set<String>] = [:]   // photo ids in Photos' smart albums

    // Swipe-up album. Saved in UserDefaults so it sticks between launches.
    @Published private(set) var albumTitle: String =
        UserDefaults.standard.string(forKey: AlbumDefaults.titleKey) ?? AlbumDefaults.title
    /// nil until the album exists in Photos (it's created on the first swipe up).
    @Published private(set) var albumID: String? = UserDefaults.standard.string(forKey: AlbumDefaults.idKey)
    @Published var albumMessage: String?             // shown when adding to the album failed

    private(set) var trashIDs: Set<String> = []
    private let keptKey = "keptPhotoIDs"
    private var filed: [String: String] = [:]        // photo id -> album id, for photos this app added
    private var albumWork: Task<Void, Never>?        // album changes run one after another

    // MARK: Loading

    func start() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        load()
        // Pick up a rename done in Photos.
        if let album = savedAlbum(), let title = album.localizedTitle, title != albumTitle {
            saveAlbum(id: album.localIdentifier, title: title)
        }
    }

    func load() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let calendar = Calendar.current
        var groups: [Int: [PHAsset]] = [:]
        result.enumerateObjects { asset, _, _ in
            var key = 0
            if let date = asset.creationDate {
                let parts = calendar.dateComponents([.year, .month], from: date)
                key = (parts.year ?? 0) * 100 + (parts.month ?? 0)
            }
            groups[key, default: []].append(asset)
        }
        months = groups.keys.sorted(by: >).map { key in
            let assets = groups[key] ?? []
            return Month(id: key,
                         title: PhotoStore.title(for: key),
                         assets: assets,
                         ids: assets.map { $0.localIdentifier })
        }
        filterIDs = PhotoFilter.loadSmartAlbums()
        loaded = true
    }

    private static func title(for key: Int) -> String {
        guard key > 0,
              let date = Calendar.current.date(from: DateComponents(year: key / 100, month: key % 100))
        else { return "No date" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: Month queries

    func month(_ id: Int) -> Month? { months.first { $0.id == id } }

    func reviewedCount(_ month: Month) -> Int {
        var count = 0
        for id in month.ids where kept.contains(id) || trashIDs.contains(id) { count += 1 }
        return count
    }

    func isDone(_ month: Month) -> Bool { reviewedCount(month) == month.ids.count }

    var doneMonthCount: Int { months.filter { isDone($0) }.count }

    func unreviewed(in monthID: Int) -> [PHAsset] {
        guard let month = month(monthID) else { return [] }
        var list: [PHAsset] = []
        for (asset, id) in zip(month.assets, month.ids) where !kept.contains(id) && !trashIDs.contains(id) {
            list.append(asset)
        }
        return list
    }

    // MARK: Reviewing

    func keep(_ asset: PHAsset) {
        kept.insert(asset.localIdentifier)
        saveKept()
    }

    func markTrash(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard !trashIDs.contains(id) else { return }
        trashIDs.insert(id)
        trash.append(asset)
    }

    /// Undo: the photo counts as not looked at again.
    /// `unfile` also takes it back out of the swipe-up album, if SwipeClean put it there.
    func unreview(_ asset: PHAsset, unfile: Bool = false) {
        let id = asset.localIdentifier
        if trashIDs.remove(id) != nil {
            trash.removeAll { $0.localIdentifier == id }
        }
        if kept.remove(id) != nil { saveKept() }
        if unfile {
            enqueueAlbumWork {
                guard let albumID = self.filed.removeValue(forKey: id),
                      let album = PHAssetCollection.fetchAssetCollections(
                          withLocalIdentifiers: [albumID], options: nil).firstObject
                else { return }
                _ = await self.perform {
                    PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
                }
            }
        }
    }

    /// Take a photo back out of the trash (counts as "keep").
    func restore(_ asset: PHAsset) {
        let id = asset.localIdentifier
        trashIDs.remove(id)
        trash.removeAll { $0.localIdentifier == id }
        kept.insert(id)
        saveKept()
    }

    /// Lets you go through a month again. Photos already in the trash stay there.
    func resetMonth(_ monthID: Int) {
        guard let month = month(monthID) else { return }
        unkeep(month.ids)
    }

    func unkeep(_ ids: [String]) {
        kept.subtract(ids)
        saveKept()
    }

    func resetAll() {
        kept = []
        saveKept()
    }

    func emptyTrash() {
        let doomed = trash
        guard !doomed.isEmpty else { return }
        let gone = Set(doomed.map { $0.localIdentifier })
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(doomed as NSArray)
        }, completionHandler: { success, _ in
            guard success else { return }
            Task { @MainActor in self.removeDeleted(gone) }
        })
    }

    private func removeDeleted(_ gone: Set<String>) {
        var updated: [Month] = []
        for month in months {
            var assets: [PHAsset] = []
            var ids: [String] = []
            for (asset, id) in zip(month.assets, month.ids) where !gone.contains(id) {
                assets.append(asset)
                ids.append(id)
            }
            if ids.isEmpty { continue }
            updated.append(Month(id: month.id, title: month.title, assets: assets, ids: ids))
        }
        months = updated
        trash.removeAll { gone.contains($0.localIdentifier) }
        trashIDs.subtract(gone)
        deleteGeneration += 1
    }

    private func saveKept() {
        UserDefaults.standard.set(Array(kept), forKey: keptKey)
    }

    // MARK: Favourites (the real Favourites album in Photos)

    func isFavorite(_ asset: PHAsset) -> Bool {
        favorites[asset.localIdentifier] ?? asset.isFavorite
    }

    func toggleFavorite(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let newValue = !isFavorite(asset)
        favorites[id] = newValue
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest(for: asset).isFavorite = newValue
        }, completionHandler: { success, _ in
            guard !success else { return }
            Task { @MainActor in self.favorites[id] = !newValue }
        })
    }

    // MARK: Swipe-up album (a real album in Photos)

    /// Albums you made in Photos, for the picker.
    func userAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { album, _, _ in albums.append(album) }
        return albums.sorted {
            ($0.localizedTitle ?? "").localizedCaseInsensitiveCompare($1.localizedTitle ?? "") == .orderedAscending
        }
    }

    func chooseAlbum(_ album: PHAssetCollection) {
        saveAlbum(id: album.localIdentifier, title: album.localizedTitle ?? AlbumDefaults.title)
    }

    /// Use an album by name. It's only created in Photos the first time you swipe up.
    func chooseNewAlbum(named name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let existing = userAlbums().first(where: { $0.localizedTitle == title }) {
            chooseAlbum(existing)
        } else {
            saveAlbum(id: nil, title: title)
        }
    }

    /// Swipe up: keeps the photo and adds it to the swipe-up album.
    func file(_ asset: PHAsset) {
        keep(asset)
        let id = asset.localIdentifier
        enqueueAlbumWork {
            guard let album = await self.ensureAlbum() else {
                self.albumMessage = "Couldn't create the album \"\(self.albumTitle)\"."
                return
            }
            if self.contains(album, asset) {
                self.filed.removeValue(forKey: id)   // was already there, so undo leaves it alone
                return
            }
            let ok = await self.perform {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
            }
            if ok {
                self.filed[id] = album.localIdentifier
            } else {
                self.albumMessage = "Couldn't add the photo to \"\(album.localizedTitle ?? self.albumTitle)\"."
            }
        }
    }

    private func savedAlbum() -> PHAssetCollection? {
        guard let id = albumID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The saved album, or one with the saved name, or a new one.
    private func ensureAlbum() async -> PHAssetCollection? {
        if let album = savedAlbum() { return album }
        let title = albumTitle
        if let existing = userAlbums().first(where: { $0.localizedTitle == title }) {
            chooseAlbum(existing)
            return existing
        }
        let created = Box()
        let ok = await perform {
            created.value = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard ok, let newID = created.value,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [newID], options: nil).firstObject
        else { return nil }
        saveAlbum(id: newID, title: title)
        return album
    }

    private func contains(_ album: PHAssetCollection, _ asset: PHAsset) -> Bool {
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var found = false
        albums.enumerateObjects { collection, _, stop in
            if collection.localIdentifier == album.localIdentifier {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func saveAlbum(id: String?, title: String) {
        albumID = id
        albumTitle = title
        UserDefaults.standard.set(id, forKey: AlbumDefaults.idKey)
        UserDefaults.standard.set(title, forKey: AlbumDefaults.titleKey)
    }

    private func enqueueAlbumWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = albumWork
        albumWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func perform(_ changes: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

// MARK: - Image loading

struct AssetImage: View {
    let asset: PHAsset
    var side: CGFloat = 1400
    var fill = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true   // fetch from iCloud if needed
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: fill ? .aspectFill : .aspectFit,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { image = result }
        }
    }
}

// MARK: - Sharing

struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Swipe card

struct SwipeCard: View {
    let asset: PHAsset
    let albumTitle: String
    let onSwipe: (SwipeAction) -> Void
    @State private var offset: CGSize = .zero

    private let threshold: CGFloat = 110

    /// The drag counts as "up" while it's more up than sideways.
    private var goingUp: Bool { -offset.height > abs(offset.width) }

    var body: some View {
        AssetImage(asset: asset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                badge(Text("KEEP"), .green).opacity(goingUp ? 0 : Double(offset.width / threshold))
            }
            .overlay(alignment: .topTrailing) {
                badge(Text("DELETE"), .red).opacity(goingUp ? 0 : Double(-offset.width / threshold))
            }
            .overlay {
                badge(Text("\(Image(systemName: "folder.fill")) \(albumTitle)"), .blue)
                    .opacity(goingUp ? Double(-offset.height / threshold) : 0)
            }
            .overlay(alignment: .bottom) {
                if let date = asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            // Follows the finger upwards; downwards stays damped.
            .offset(x: offset.width, y: offset.height < 0 ? offset.height : offset.height * 0.25)
            .rotationEffect(.degrees(Double(offset.width) / 22))
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        let move = value.translation
                        if -move.height > threshold && -move.height > abs(move.width) {
                            fling(.file)
                        } else if abs(move.width) > threshold {
                            fling(move.width < 0 ? .delete : .keep)
                        } else {
                            withAnimation(.spring()) { offset = .zero }
                        }
                    }
            )
    }

    private func badge(_ text: Text, _ color: Color) -> some View {
        text
            .font(.title3.weight(.heavy))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .padding(18)
    }

    private func fling(_ action: SwipeAction) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) {
            switch action {
            case .delete: offset = CGSize(width: -700, height: 0)
            case .keep: offset = CGSize(width: 700, height: 0)
            case .file: offset = CGSize(width: offset.width, height: -1100)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSwipe(action) }
    }
}

// MARK: - Swipe-up album picker

struct AlbumPicker: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums, id: \.localIdentifier) { album in
                        Button {
                            store.chooseAlbum(album)
                            dismiss()
                        } label: {
                            row(album.localizedTitle ?? "Untitled",
                                selected: album.localIdentifier == store.albumID)
                        }
                    }
                    // Chosen by name but not in Photos yet (or deleted there).
                    if !albums.contains(where: { $0.localIdentifier == store.albumID }) {
                        row(store.albumTitle, note: "created on first swipe up", selected: true)
                    }
                } header: {
                    Text("Swipe up adds the photo to")
                } footer: {
                    Text("Your choice is remembered. The photo also stays where it is in your library.")
                }
                Section {
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        Label("New album…", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Swipe-up album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New album", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Use") {
                    store.chooseNewAlbum(named: newName)
                    dismiss()
                }
            }
        }
        .onAppear { albums = store.userAlbums() }
    }

    private func row(_ title: String, note: String? = nil, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Trash review

struct TrashView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(store.trash, id: \.localIdentifier) { asset in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { AssetImage(asset: asset, side: 300, fill: true) }
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { store.restore(asset) }
                    }
                }
                Text("Tap a photo to keep it instead.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
            .navigationTitle("\(store.trash.count) to delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete all", role: .destructive) {
                        store.emptyTrash()
                        dismiss()
                    }
                    .disabled(store.trash.isEmpty)
                }
            }
        }
    }
}

struct TrashButton: View {
    @ObservedObject var store: PhotoStore
    @Binding var showTrash: Bool

    var body: some View {
        Button { showTrash = true } label: {
            Label("\(store.trash.count)", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .disabled(store.trash.isEmpty)
    }
}

// MARK: - Month list

struct MonthRow: View {
    let title: String
    let reviewed: Int
    let total: Int

    var body: some View {
        let done = reviewed == total
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(done ? "Done · \(total) photos" : "\(reviewed) of \(total) reviewed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !done && reviewed > 0 {
                    ProgressView(value: Double(reviewed), total: Double(total))
                }
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MonthListView: View {
    @ObservedObject var store: PhotoStore
    @ObservedObject var places: PlaceIndex
    @ObservedObject var content: ContentIndex
    @Binding var showTrash: Bool
    @State private var confirmReset = false
    @State private var searchText = ""
    @State private var filters: Set<PhotoFilter> = []

    private var query: SearchQuery { SearchQuery(text: searchText, filters: filters) }

    var body: some View {
        Group {
            if query.isEmpty {
                monthList
            } else {
                SearchResultsView(store: store, places: places, content: content, query: query)
            }
        }
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Places, things, text, months…")
        .searchSuggestions { suggestions }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterChips(filters: $filters, text: $searchText, places: places.topPlaces(8))
        }
        .safeAreaInset(edge: .bottom) {
            if !store.trash.isEmpty {
                Button { showTrash = true } label: {
                    Text("Review & delete \(store.trash.count)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reset all progress", role: .destructive) { confirmReset = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                TrashButton(store: store, showTrash: $showTrash)
            }
        }
        .confirmationDialog("Mark every month as not reviewed?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset all progress", role: .destructive) { store.resetAll() }
        }
    }

    private var monthList: some View {
        List {
            Section {
                ForEach(store.months) { month in
                    NavigationLink(value: DeckSource.month(month.id)) {
                        MonthRow(title: month.title,
                                 reviewed: store.reviewedCount(month),
                                 total: month.ids.count)
                    }
                }
            } header: {
                Text("\(store.doneMonthCount) of \(store.months.count) months done")
            }
        }
        .overlay {
            if store.loaded && store.months.isEmpty {
                Text("No photos found").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        let typed = searchText.folded.trimmingCharacters(in: .whitespaces)
        if typed.count >= 2 {
            ForEach(PhotoFilter.allCases.filter { $0.matches(word: typed) }) { filter in
                Label(filter.title, systemImage: filter.icon).searchCompletion(filter.title)
            }
            ForEach(content.suggestions(for: typed), id: \.self) { name in
                Label(name.capitalized, systemImage: "sparkle.magnifyingglass").searchCompletion(name)
            }
            ForEach(places.suggestions(for: typed), id: \.self) { name in
                Label(name, systemImage: "mappin.and.ellipse").searchCompletion(name)
            }
        }
    }
}

// MARK: - Swiping through a month or search results

struct DeckView: View {
    @ObservedObject var store: PhotoStore
    let source: DeckSource
    let places: PlaceIndex
    let content: ContentIndex
    @Binding var showTrash: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var queue: [PHAsset] = []
    @State private var index = 0
    @State private var undoFloor = 0      // can't undo past photos that were really deleted
    @State private var prepared = false
    @State private var shareItem: ShareItem?
    @State private var preparingShare = false
    @State private var history: [SwipeAction] = []   // what each swipe did, for undo
    @State private var showAlbumPicker = false

    private var current: PHAsset? { index < queue.count ? queue[index] : nil }

    var body: some View {
        VStack(spacing: 14) {
            if let asset = current {
                HStack {
                    Text("\(queue.count - index) left")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { showAlbumPicker = true } label: {
                        Label(store.albumTitle, systemImage: "arrow.up.square")
                            .lineLimit(1)
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                .padding(.horizontal)

                SwipeCard(asset: asset, albumTitle: store.albumTitle) { act($0) }
                    .id(asset.localIdentifier)
                    .padding(.horizontal)

                HStack(spacing: 10) {
                    roundButton("trash.fill", .red) { act(.delete) }
                    roundButton("arrow.uturn.backward", .gray) { undo() }
                        .disabled(index <= undoFloor)
                    roundButton(store.isFavorite(asset) ? "heart.fill" : "heart", .pink) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.toggleFavorite(asset)
                    }
                    roundButton("square.and.arrow.up", .blue) { share(asset) }
                        .disabled(preparingShare)
                    roundButton("folder.badge.plus", .indigo) { act(.file) }
                    roundButton("checkmark", .green) { act(.keep) }
                }
            } else if prepared {
                doneView
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }

            if !store.trash.isEmpty {
                Button { showTrash = true } label: {
                    Text("Review & delete \(store.trash.count)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .navigationTitle(store.title(for: source))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TrashButton(store: store, showTrash: $showTrash)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.image])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPicker(store: store)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            if !prepared { rebuild() }
        }
        .onChange(of: store.deleteGeneration) {
            undoFloor = index
        }
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(isMonth ? "Month done" : "All done").font(.title2.weight(.semibold))
            if !store.trash.isEmpty {
                Text("Photos you marked are deleted once you confirm below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button(isMonth ? "Back to months" : "Back to search") { dismiss() }
                .buttonStyle(.borderedProminent)
            if !store.assets(for: source, places: places, content: content).isEmpty {
                Button(isMonth ? "Review this month again" : "Review these again") {
                    store.reviewAgain(source, places: places, content: content)
                    rebuild()
                }
            }
            Spacer()
        }
    }

    private var isMonth: Bool {
        if case .month = source { return true }
        return false
    }

    private func rebuild() {
        queue = store.unreviewed(source, places: places, content: content)
        index = 0
        undoFloor = 0
        history = []
        prepared = true
    }

    private func act(_ action: SwipeAction) {
        guard let asset = current else { return }
        switch action {
        case .delete: store.markTrash(asset)
        case .keep: store.keep(asset)
        case .file: store.file(asset)
        }
        history.append(action)
        index += 1
    }

    private func undo() {
        guard index > undoFloor else { return }
        index -= 1
        let last = history.popLast()
        store.unreview(queue[index], unfile: last == .file)
    }

    private func share(_ asset: PHAsset) {
        preparingShare = true
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: options
        ) { result, _ in
            DispatchQueue.main.async {
                preparingShare = false
                if let result { shareItem = ShareItem(image: result) }
            }
        }
    }

    private func roundButton(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 50, height: 50)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = PhotoStore()
    @StateObject private var places = PlaceIndex()
    @StateObject private var content = ContentIndex()
    @State private var showTrash = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.status {
                case .authorized, .limited:
                    MonthListView(store: store, places: places, content: content, showTrash: $showTrash)
                case .notDetermined:
                    ProgressView()
                default:
                    denied
                }
            }
            .navigationTitle("SwipeClean")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DeckSource.self) { source in
                DeckView(store: store, source: source, places: places, content: content, showTrash: $showTrash)
            }
        }
        .sheet(isPresented: $showTrash) { TrashView(store: store) }
        .alert(
            "Swipe-up album",
            isPresented: Binding(
                get: { store.albumMessage != nil },
                set: { if !$0 { store.albumMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.albumMessage ?? "")
        }
        .task { await store.start() }
        .onChange(of: store.loaded) {
            if store.loaded {
                places.start(months: store.months)
                content.start(months: store.months, screenshots: store.filterIDs[.screenshots] ?? [])
            }
        }
    }

    private var denied: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 50))
            Text("SwipeClean needs access to your photos.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
