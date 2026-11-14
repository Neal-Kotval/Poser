import PhotosUI
import SwiftUI

struct ProfileView: View {
    @ObservedObject var profileStore: UserProfileStore
    @ObservedObject var shootStore: ShootStore
    let onOpenCamera: () -> Void
    let onSelectShot: (CompletedShot) -> Void

    @State private var editingName = false
    @State private var draftName = ""
    @State private var avatarPicker: PhotosPickerItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PoserSpace.large) {
                header
                gallery
            }
            .foregroundStyle(Palette.primaryText)
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, PoserSpace.large)
            .padding(.bottom, PoserSpace.xLarge)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .alert("Display name", isPresented: $editingName) {
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { profileStore.updateDisplayName(draftName) }
        } message: {
            Text("This name stays on this phone. No account is required.")
        }
        .onChange(of: avatarPicker) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                try? profileStore.updateAvatar(image)
                avatarPicker = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PoserSpace.regular) {
            HStack(alignment: .center, spacing: PoserSpace.regular) {
                PhotosPicker(selection: $avatarPicker, matching: .images) {
                    avatar
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile photo")

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        draftName = profileStore.profile.displayName
                        editingName = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(profileStore.profile.displayName)
                                .font(.system(size: 28, weight: .bold))
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit display name")

                    Text("\(shootStore.shots.count) \(shootStore.shots.count == 1 ? "shot" : "shots")")
                        .font(PoserType.supporting)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                profileStat(title: "Shots", value: "\(shootStore.shots.count)")
                profileStat(title: "This week", value: "\(shotsThisWeek)")
                profileStat(title: "Latest", value: latestShotLabel)
            }
            .padding(.vertical, PoserSpace.small)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
            .overlay(RoundedRectangle(cornerRadius: PoserRadius.surface).stroke(Palette.border))
        }
    }

    private var avatar: some View {
        ZStack {
            if let image = profileStore.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(profileStore.initials)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.primaryText)
            }
        }
        .frame(width: 84, height: 84)
        .background(Palette.elevated)
        .clipShape(Circle())
        .overlay(Circle().stroke(Palette.border, lineWidth: 1))
    }

    private func profileStat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PoserSpace.medium)
    }

    @ViewBuilder
    private var gallery: some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            Text("Gallery")
                .font(PoserType.title)

            if shootStore.shots.isEmpty {
                VStack(alignment: .leading, spacing: PoserSpace.medium) {
                    Text("Your shoots will live here")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Take a shot from the camera tab to start a collection.")
                        .font(PoserType.supporting)
                        .foregroundStyle(Palette.secondaryText)
                    Button("Open camera", action: onOpenCamera)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 4)
                }
                .padding(.top, PoserSpace.large)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(shootStore.shots) { shot in
                        if let photo = shootStore.photo(for: shot) {
                            Button { onSelectShot(shot) } label: {
                                GeometryReader { tile in
                                    Image(uiImage: photo)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: tile.size.width, height: tile.size.height)
                                        .clipped()
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .background(Palette.surface)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Shot from \(shot.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
            }
        }
    }

    private var shotsThisWeek: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        return shootStore.shots.filter { $0.createdAt >= weekAgo }.count
    }

    private var latestShotLabel: String {
        guard let latest = shootStore.shots.first else { return "—" }
        return latest.createdAt.formatted(date: .abbreviated, time: .omitted)
    }
}
