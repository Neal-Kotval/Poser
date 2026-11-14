import PhotosUI
import SwiftUI

struct ProfileView: View {
    @ObservedObject var profileStore: UserProfileStore
    @ObservedObject var shootStore: ShootStore
    let onOpenCamera: () -> Void
    let onSelectShot: (CompletedShot) -> Void

    @State private var editingProfile = false
    @State private var avatarPicker: PhotosPickerItem?
    @State private var avatarDraft: AvatarDraft?
    @State private var avatarError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

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
            .padding(.bottom, 86)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .sheet(isPresented: $editingProfile) {
            EditProfileView(profile: profileStore.profile) { name, bio in
                profileStore.updateDisplayName(name)
                profileStore.updateBio(bio)
                editingProfile = false
            } onCancel: {
                editingProfile = false
            }
            .presentationDetents([.large])
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(profileStore.profile.displayName)
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let bio = profileStore.profile.bio {
                        Text(bio)
                            .font(PoserType.supporting)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                profileStat(title: "Shots", value: "\(shootStore.shots.count)")
                profileStat(title: "Best match", value: shootStore.bestMatch.map { "\($0)%" } ?? "—")
                profileStat(title: "Poses tried", value: "\(shootStore.posesTried)")
            }
            .padding(.vertical, PoserSpace.small)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
            .overlay(RoundedRectangle(cornerRadius: PoserRadius.surface).stroke(Palette.border))

            Button { editingProfile = true } label: {
                Text("Edit profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
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

    /// Equal thirds: a long value shrinks instead of squeezing its neighbors.
    private func profileStat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PoserSpace.xSmall)
        .padding(.vertical, PoserSpace.medium)
    }

    @ViewBuilder
    private var gallery: some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            Text("Shots")
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
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(shootStore.shots) { shot in
                        if let photo = shootStore.photo(for: shot) {
                            Button { onSelectShot(shot) } label: {
                                pairedTile(photo: photo, reference: shootStore.reference(for: shot),
                                           score: shot.matchScore)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Shot from \(shot.createdAt.formatted(date: .abbreviated, time: .omitted))"
                                + (shot.matchScore.map { ", \($0) percent match" } ?? ""))
                        }
                    }
                }
            }
        }
    }

    /// My shot fills the tile; the reference it recreates sits in the corner, like BeReal's front-camera bubble.
    private func pairedTile(photo: UIImage, reference: UIImage?, score: Int?) -> some View {
        GeometryReader { tile in
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: tile.size.width, height: tile.size.height)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let reference {
                        Image(uiImage: reference)
                            .resizable()
                            .scaledToFill()
                            .frame(width: tile.size.width * 0.36, height: tile.size.width * 0.36)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.black, lineWidth: 1.5))
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let score {
                        Text("\(score)%")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(5)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .background(Palette.surface)
    }
}

struct EditProfileView: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var bio: String

    init(profile: UserProfile, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: profile.displayName)
        _bio = State(initialValue: profile.bio ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PoserSpace.regular) {
            HStack {
                Button("Cancel", action: onCancel)
                    .frame(minHeight: 44)
                Spacer()
                Text("Edit profile").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Save") { onSave(name, bio) }
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            field("Name", count: name.count, limit: UserProfile.nameLimit) {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, value in
                        let clean = value.replacingOccurrences(of: "\n", with: " ")
                        let limited = String(clean.prefix(UserProfile.nameLimit))
                        if limited != value { name = limited }
                    }
            }
            field("Bio", count: bio.count, limit: UserProfile.bioLimit) {
                TextField("Tell people about you", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: bio) { _, value in
                        if value.count > UserProfile.bioLimit { bio = String(value.prefix(UserProfile.bioLimit)) }
                    }
            }
            Text("Your profile stays on this phone. No account is required.")
                .font(PoserType.caption)
                .foregroundStyle(Palette.secondaryText)
            Spacer()
        }
        .padding(PoserSpace.large)
        .foregroundStyle(.white)
        .background(Palette.background.ignoresSafeArea())
    }

    private func field<Content: View>(_ label: String, count: Int, limit: Int,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(count)/\(limit)")
                    .monospacedDigit()
                    .accessibilityLabel("\(count) of \(limit) characters")
            }
            .font(PoserType.caption)
            .foregroundStyle(Palette.secondaryText)
            content()
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A completed shot as a post: reference and shot side by side, the match score, and share.
struct ShotPostView: View {
    let shot: CompletedShot
    @ObservedObject var shootStore: ShootStore
    let onDeleted: () -> Void

    @State private var shareCard: UIImage?
    @State private var message: String?
    @State private var confirmingDelete = false

    var body: some View {
        let photo = shootStore.photo(for: shot)
        let reference = shootStore.reference(for: shot)
        ScrollView {
            VStack(alignment: .leading, spacing: PoserSpace.large) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shot.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 17, weight: .semibold))
                        Text(shot.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(PoserType.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    Menu {
                        if let photo {
                            Button { save(photo) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        }
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete shot", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More")
                }

                HStack(spacing: 8) {
                    if let reference { postImage(reference, label: "REFERENCE") }
                    if let photo { postImage(photo, label: "MY SHOT") }
                }

                if let score = shot.matchScore {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(score)%")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("match")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let shareCard {
                    ShareLink(item: Image(uiImage: shareCard),
                              preview: SharePreview("My Poser shot", image: Image(uiImage: shareCard))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.white, in: Capsule())
                    }
                }
            }
            .padding(PoserSpace.large)
            .foregroundStyle(.white)
        }
        .background(Palette.background.ignoresSafeArea())
        .task {
            if let photo, let reference {
                shareCard = ShareCardRenderer.render(reference: reference, shot: photo, score: shot.matchScore)
            }
        }
        .confirmationDialog("Delete this shot?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete shot", role: .destructive) {
                do {
                    try shootStore.remove(shot)
                    onDeleted()
                } catch {
                    message = "This shot could not be deleted. Try again."
                }
            }
        } message: {
            Text("It's removed from Poser. Your Photos library is unchanged.")
        }
        .alert("Poser", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func postImage(_ image: UIImage, label: String) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { Image(uiImage: image).resizable().scaledToFill() }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(8)
            }
            .accessibilityLabel(label == "REFERENCE" ? "Reference photo" : "My shot")
    }

    private func save(_ photo: UIImage) {
        PhotoLibrarySaver.save(photo) { success in
            message = success ? "Your shot is in Photos." : "Allow Photos access in Settings to save this shot."
        }
    }
}

/// Draws the shareable card: reference and shot side by side, the score, and the wordmark.
enum ShareCardRenderer {
    static func render(reference: UIImage, shot: UIImage, score: Int?) -> UIImage {
        let size = CGSize(width: 1080, height: 1350)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let margin: CGFloat = 48, gap: CGFloat = 16
            let width = (size.width - margin * 2 - gap) / 2
            let height = width * 4 / 3
            let y: CGFloat = 220
            drawFilled(reference, in: CGRect(x: margin, y: y, width: width, height: height), context: context.cgContext)
            drawFilled(shot, in: CGRect(x: margin + width + gap, y: y, width: width, height: height), context: context.cgContext)

            let label: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor(white: 0.7, alpha: 1), .kern: 2
            ]
            NSString(string: "REFERENCE").draw(at: CGPoint(x: margin, y: y - 44), withAttributes: label)
            NSString(string: "MY SHOT").draw(at: CGPoint(x: margin + width + gap, y: y - 44), withAttributes: label)

            let wordmark: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: UIColor.white, .kern: -2
            ]
            NSString(string: "poser").draw(at: CGPoint(x: margin, y: 70), withAttributes: wordmark)

            if let score {
                let big: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: UIColor.white
                ]
                let small: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: UIColor(white: 0.7, alpha: 1)
                ]
                let scoreText = NSString(string: "\(score)%")
                let scoreY = y + height + 40
                scoreText.draw(at: CGPoint(x: margin, y: scoreY), withAttributes: big)
                let scoreWidth = scoreText.size(withAttributes: big).width
                NSString(string: "pose match").draw(at: CGPoint(x: margin + scoreWidth + 20, y: scoreY + 66), withAttributes: small)
            }
        }
    }

    private static func drawFilled(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 28).addClip()
        let scale = max(rect.width / max(image.size.width, 1), rect.height / max(image.size.height, 1))
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height))
        context.restoreGState()
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
