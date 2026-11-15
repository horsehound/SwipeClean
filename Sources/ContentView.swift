// SwipeClean – a tiny swipe-to-clean photo app.
// Swipe LEFT = mark for deletion, swipe RIGHT = keep.
// Nothing is deleted until you tap "Delete" and confirm the iOS prompt.
//
// Setup: new Xcode project (iOS > App, SwiftUI), replace ContentView.swift with this file,
// and add the Info key "Privacy - Photo Library Usage Description" (NSPhotoLibraryUsageDescription).

import SwiftUI
import Photos
import UIKit

// MARK: - Model

@MainActor
final class PhotoStore: ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PHAsset] = []
    @Published var index = 0
    @Published var trash: [PHAsset] = []
    @Published var history: [Bool] = []   // true = that swipe was a "delete"

    private let keptKey = "keptPhotoIDs"
    private var kept: Set<String> = []

    var current: PHAsset? { index < assets.count ? assets[index] : nil }
    var remaining: Int { max(assets.count - index, 0) }

    func start() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        load()
    }

    func load(shuffled: Bool = false) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if !self.kept.contains(asset.localIdentifier) { list.append(asset) }
        }
        assets = shuffled ? list.shuffled() : list
        index = 0
        trash = []
        history = []
    }

    func swipe(delete: Bool) {
        guard let asset = current else { return }
        if delete {
            trash.append(asset)
        } else {
            kept.insert(asset.localIdentifier)
            saveKept()
        }
        history.append(delete)
        index += 1
    }

    func undo() {
        guard let wasDelete = history.popLast(), index > 0 else { return }
        index -= 1
        let asset = assets[index]
        if wasDelete {
            if !trash.isEmpty { trash.removeLast() }
        } else {
            kept.remove(asset.localIdentifier)
            saveKept()
        }
    }

    /// Take a photo back out of the trash (counts as "keep").
    func restore(_ asset: PHAsset) {
        trash.removeAll { $0.localIdentifier == asset.localIdentifier }
        kept.insert(asset.localIdentifier)
        saveKept()
        history = []   // undo chain no longer matches the trash
    }

    func emptyTrash() {
        let doomed = trash
        guard !doomed.isEmpty else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(doomed as NSArray)
        }, completionHandler: { success, _ in
            guard success else { return }
            Task { @MainActor in
                self.trash = []
                self.history = []
            }
        })
    }

    func resetProgress() {
        kept = []
        saveKept()
        load()
    }

    private func saveKept() {
        UserDefaults.standard.set(Array(kept), forKey: keptKey)
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

// MARK: - Main screen

struct ContentView: View {
    @StateObject private var store = PhotoStore()
    @State private var showTrash = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.status {
                case .authorized, .limited: deck
                case .notDetermined: ProgressView()
                default: denied
                }
            }
            .navigationTitle("SwipeClean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Newest first") { store.load() }
                        Button("Shuffle") { store.load(shuffled: true) }
                        Button("Reset progress", role: .destructive) { store.resetProgress() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTrash = true } label: {
                        Label("\(store.trash.count)", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(store.trash.isEmpty)
                }
            }
            .sheet(isPresented: $showTrash) { TrashView(store: store) }
        }
        .task { await store.start() }
    }

    private var deck: some View {
        VStack(spacing: 14) {
            Text("\(store.remaining) left")
                .font(.footnote).foregroundStyle(.secondary)

            if let asset = store.current {
                SwipeCard(asset: asset) { store.swipe(delete: $0) }
                    .id(asset.localIdentifier)
                    .padding(.horizontal)
            } else {
                Spacer()
                Image(systemName: "checkmark.circle").font(.system(size: 60)).foregroundStyle(.green)
                Text("All done").font(.title2.weight(.semibold))
                Spacer()
            }

            HStack(spacing: 36) {
                roundButton("trash.fill", .red) { store.swipe(delete: true) }
                    .disabled(store.current == nil)
                roundButton("arrow.uturn.backward", .gray) { store.undo() }
                    .disabled(store.history.isEmpty)
                roundButton("heart.fill", .green) { store.swipe(delete: false) }
                    .disabled(store.current == nil)
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
    }

    private func roundButton(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 62, height: 62)
                .background(Color(.secondarySystemBackground), in: Circle())
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
