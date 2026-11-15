// SwipeClean – a tiny swipe-to-clean photo app.
// Pick a month, then swipe LEFT = mark for deletion, swipe RIGHT = keep.
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

@MainActor
final class PhotoStore: ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var months: [Month] = []
    @Published var kept: Set<String> = []
    @Published var trash: [PHAsset] = []
    @Published var favorites: [String: Bool] = [:]   // local overrides after toggling
    @Published var deleteGeneration = 0              // bumps whenever photos were really deleted
    @Published var loaded = false

    private var trashIDs: Set<String> = []
    private let keptKey = "keptPhotoIDs"

    // MARK: Loading

    func start() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        load()
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
    func unreview(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if trashIDs.remove(id) != nil {
            trash.removeAll { $0.localIdentifier == id }
        }
        if kept.remove(id) != nil { saveKept() }
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
        kept.subtract(month.ids)
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
    let onSwipe: (Bool) -> Void
    @State private var offset: CGSize = .zero

    private let threshold: CGFloat = 110

    var body: some View {
        AssetImage(asset: asset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topLeading) { badge("KEEP", .green).opacity(Double(offset.width / threshold)) }
            .overlay(alignment: .topTrailing) { badge("DELETE", .red).opacity(Double(-offset.width / threshold)) }
            .overlay(alignment: .bottom) {
                if let date = asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .offset(x: offset.width, y: offset.height * 0.25)
            .rotationEffect(.degrees(Double(offset.width) / 22))
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        if abs(value.translation.width) > threshold {
                            fling(delete: value.translation.width < 0)
                        } else {
                            withAnimation(.spring()) { offset = .zero }
                        }
                    }
            )
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.title3.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .padding(18)
    }

    private func fling(delete: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) {
            offset = CGSize(width: delete ? -700 : 700, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSwipe(delete) }
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
    @Binding var showTrash: Bool
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                ForEach(store.months) { month in
                    NavigationLink(value: month.id) {
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
}

// MARK: - Swiping through one month

struct DeckView: View {
    @ObservedObject var store: PhotoStore
    let monthID: Int
    @Binding var showTrash: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var queue: [PHAsset] = []
    @State private var index = 0
    @State private var undoFloor = 0      // can't undo past photos that were really deleted
    @State private var prepared = false
    @State private var shareItem: ShareItem?
    @State private var preparingShare = false

    private var current: PHAsset? { index < queue.count ? queue[index] : nil }

    var body: some View {
        VStack(spacing: 14) {
            if let asset = current {
                Text("\(queue.count - index) left")
                    .font(.footnote).foregroundStyle(.secondary)

                SwipeCard(asset: asset) { act(delete: $0) }
                    .id(asset.localIdentifier)
                    .padding(.horizontal)

                HStack(spacing: 14) {
                    roundButton("trash.fill", .red) { act(delete: true) }
                    roundButton("arrow.uturn.backward", .gray) { undo() }
                        .disabled(index <= undoFloor)
                    roundButton(store.isFavorite(asset) ? "heart.fill" : "heart", .pink) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.toggleFavorite(asset)
                    }
                    roundButton("square.and.arrow.up", .blue) { share(asset) }
                        .disabled(preparingShare)
                    roundButton("checkmark", .green) { act(delete: false) }
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
        .navigationTitle(store.month(monthID)?.title ?? "SwipeClean")
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
            Text("Month done").font(.title2.weight(.semibold))
            if !store.trash.isEmpty {
                Text("Photos you marked are deleted once you confirm below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("Back to months") { dismiss() }
                .buttonStyle(.borderedProminent)
            if store.month(monthID) != nil {
                Button("Review this month again") {
                    store.resetMonth(monthID)
                    rebuild()
                }
            }
            Spacer()
        }
    }

    private func rebuild() {
        queue = store.unreviewed(in: monthID)
        index = 0
        undoFloor = 0
        prepared = true
    }

    private func act(delete: Bool) {
        guard let asset = current else { return }
        if delete {
            store.markTrash(asset)
        } else {
            store.keep(asset)
        }
        index += 1
    }

    private func undo() {
        guard index > undoFloor else { return }
        index -= 1
        store.unreview(queue[index])
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
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = PhotoStore()
    @State private var showTrash = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.status {
                case .authorized, .limited:
                    MonthListView(store: store, showTrash: $showTrash)
                case .notDetermined:
                    ProgressView()
                default:
                    denied
                }
            }
            .navigationTitle("SwipeClean")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { monthID in
                DeckView(store: store, monthID: monthID, showTrash: $showTrash)
            }
        }
        .sheet(isPresented: $showTrash) { TrashView(store: store) }
        .task { await store.start() }
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
