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
    @State private var avatarDraft: AvatarDraft?
    @State private var avatarError: String?

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
            avatarPicker = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    avatarError = "This photo could not be opened. Try another one."
                    return
                }
                avatarDraft = AvatarDraft(image: image)
            }
        }
        .fullScreenCover(item: $avatarDraft) { draft in
            AvatarCropView(image: draft.image) {
                avatarDraft = nil
            } onDone: { cropped in
                do {
                    try profileStore.updateAvatar(cropped)
                    avatarDraft = nil
                } catch {
                    avatarDraft = nil
                    avatarError = "Your profile photo could not be saved. Try again."
                }
            }
        }
        .alert("Profile photo", isPresented: Binding(
            get: { avatarError != nil },
            set: { if !$0 { avatarError = nil } }
        )) {
            Button("OK", role: .cancel) { avatarError = nil }
        } message: { Text(avatarError ?? "") }
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

struct AvatarDraft: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Instagram-style preview: the new photo is shown in the profile circle and can be
/// dragged and pinched into place. Nothing is saved until Done.
struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 48, 340)
            ZStack {
                Color.black

                Image(uiImage: image)
                    .resizable()
                    .frame(width: displayedSize(side: side, scale: scale).width,
                           height: displayedSize(side: side, scale: scale).height)
                    .offset(offset)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .accessibilityHidden(true)

                Rectangle()
                    .fill(.black.opacity(0.62))
                    .mask {
                        Rectangle()
                            .overlay(Circle().frame(width: side, height: side).blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)

                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamp(CGSize(width: committedOffset.width + value.translation.width,
                                              height: committedOffset.height + value.translation.height),
                                       side: side, scale: scale)
                    }
                    .onEnded { _ in committedOffset = offset }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(committedScale * value.magnification, 1), maxScale)
                            offset = clamp(offset, side: side, scale: scale)
                        }
                        .onEnded { _ in
                            committedScale = scale
                            committedOffset = offset
                        })
            )
            .overlay {
                // Controls sit inside the safe area, away from the Dynamic Island and home bar.
                VStack(spacing: PoserSpace.small) {
                    Text("Move and scale")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, geometry.safeAreaInsets.top + PoserSpace.regular)
                    Spacer()
                    Text("Drag to move · pinch to zoom")
                        .font(PoserType.supporting)
                        .foregroundStyle(Palette.secondaryText)
                    HStack(spacing: PoserSpace.medium) {
                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Palette.elevated, in: Capsule())
                        }
                        Button { onDone(render(side: side)) } label: {
                            Text("Done")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(.white, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, PoserSpace.large)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + PoserSpace.regular)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Size of the photo on screen: scaled to just fill the circle, then zoomed.
    private func displayedSize(side: CGFloat, scale: CGFloat) -> CGSize {
        let width = max(image.size.width, 1)
        let height = max(image.size.height, 1)
        let fill = max(side / width, side / height) * scale
        return CGSize(width: width * fill, height: height * fill)
    }

    /// Keeps the photo covering the whole circle so the avatar never shows an empty edge.
    private func clamp(_ proposed: CGSize, side: CGFloat, scale: CGFloat) -> CGSize {
        let size = displayedSize(side: side, scale: scale)
        let limitX = max(0, (size.width - side) / 2)
        let limitY = max(0, (size.height - side) / 2)
        return CGSize(width: min(max(proposed.width, -limitX), limitX),
                      height: min(max(proposed.height, -limitY), limitY))
    }

    /// Renders exactly the area inside the circle as a square image.
    private func render(side: CGFloat) -> UIImage {
        let output: CGFloat = 800
        let factor = output / side
        let shown = displayedSize(side: side, scale: scale)
        let drawSize = CGSize(width: shown.width * factor, height: shown.height * factor)
        let origin = CGPoint(x: (output - drawSize.width) / 2 + offset.width * factor,
                             y: (output - drawSize.height) / 2 + offset.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
