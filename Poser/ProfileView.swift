import Charts
import PhotosUI
import SwiftUI

struct ProfileView: View {
    @ObservedObject var profileStore: UserProfileStore
    @ObservedObject var shootStore: ShootStore
    @ObservedObject var inspirationStore: InspirationStore
    let onOpenReference: (InspirationItem) -> Void
    let onAddPoses: ([PhotosPickerItem]) -> Void
    let onDeleteReference: (UUID) -> Void
    let onOpenCamera: () -> Void
    let onSelectShot: (CompletedShot) -> Void

    @State private var editingProfile = false
    @State private var selectedTab: ProfileTab = .shots
    @State private var posePicks: [PhotosPickerItem] = []

    private enum ProfileTab { case shots, poses, progress }
    @State private var avatarPicker: PhotosPickerItem?
    @State private var avatarDraft: AvatarDraft?
    @State private var avatarError: String?
    @State private var profileCard: UIImage?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var insights: ProfileInsights {
        ProfileInsights(shots: shootStore.shots, savedPoses: inspirationStore.items.count)
    }

    /// Changes whenever something shown on the share card changes.
    private var cardKey: String {
        let profile = profileStore.profile
        return [profile.displayName, profile.bio ?? "", "\(shootStore.shots.count)",
                "\(shootStore.bestMatch ?? -1)", "\(inspirationStore.items.count)"].joined(separator: "|")
    }

    var body: some View {
        let insights = self.insights
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PoserSpace.large) {
                header(insights)
                VStack(spacing: PoserSpace.medium) {
                    tabBar
                    switch selectedTab {
                    case .shots: gallery
                    case .poses: poses
                    case .progress: progress(insights)
                    }
                }
            }
            .foregroundStyle(Palette.primaryText)
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, PoserSpace.large)
            .padding(.bottom, 86)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .task(id: cardKey) { renderProfileCard() }
        .onChange(of: posePicks) { _, items in
            guard !items.isEmpty else { return }
            posePicks = []
            onAddPoses(items)
        }
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
                    renderProfileCard()
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

    // MARK: Header

    private func header(_ insights: ProfileInsights) -> some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            HStack(alignment: .center, spacing: PoserSpace.large) {
                PhotosPicker(selection: $avatarPicker, matching: .images) {
                    avatar(onStreak: insights.currentStreak > 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile photo")

                HStack(spacing: 0) {
                    headerStat(value: "\(insights.shotCount)", title: "Shots")
                    headerStat(value: insights.bestMatch.map { "\($0)%" } ?? "—", title: "Best match")
                    headerStat(value: "\(insights.posesTried)", title: "Poses tried")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: PoserSpace.small) {
                    Text(profileStore.profile.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if insights.currentStreak > 0 {
                        streakChip(insights.currentStreak)
                    }
                }
                if let bio = profileStore.profile.bio {
                    Text(bio)
                        .font(PoserType.supporting)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: PoserSpace.small) {
                Button { editingProfile = true } label: {
                    headerButtonLabel("Edit profile", symbol: nil)
                }
                .buttonStyle(.plain)
                if let profileCard {
                    ShareLink(item: Image(uiImage: profileCard),
                              preview: SharePreview("\(profileStore.profile.displayName) on Poser",
                                                    image: Image(uiImage: profileCard))) {
                        headerButtonLabel("Share profile", symbol: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func headerButtonLabel(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(Palette.primaryText)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func streakChip(_ days: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill").font(.system(size: 11, weight: .bold))
            Text("\(days)").font(.system(size: 12, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days)-day shooting streak")
    }

    /// A white ring marks an active streak, the way stories rings mark something new.
    private func avatar(onStreak: Bool) -> some View {
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
        .padding(4)
        .overlay(Circle().stroke(onStreak ? Palette.primaryText : .clear, lineWidth: 2))
    }

    /// Instagram-style count: value over label, equal thirds, long values shrink.
    private func headerStat(value: String, title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Match trend

    /// Poser's own stat: are your recreations getting closer to the reference?
    private func trendCard(_ insights: ProfileInsights) -> some View {
        let points = Array(insights.recentScores.enumerated())
        return VStack(alignment: .leading, spacing: PoserSpace.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Match trend").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(insights.trendHeadline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Chart {
                ForEach(points, id: \.offset) { index, score in
                    LineMark(x: .value("Shot", index + 1), y: .value("Match", score))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Palette.primaryText)
                    PointMark(x: .value("Shot", index + 1), y: .value("Match", score))
                        .foregroundStyle(Palette.primaryText)
                        .symbolSize(24)
                }
                if let average = insights.averageScore {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 10)) }
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
            .frame(height: 110)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Match trend over your last \(points.count) scored shots. \(insights.trendHeadline).")
        }
        .padding(PoserSpace.regular)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Progress

    private func progress(_ insights: ProfileInsights) -> some View {
        VStack(alignment: .leading, spacing: PoserSpace.large) {
            HStack(spacing: 10) {
                progressFact(value: "\(insights.currentStreak)", title: "Day streak", symbol: "flame.fill")
                progressFact(value: "\(insights.longestStreak)", title: "Longest streak", symbol: "calendar")
                progressFact(value: insights.averageScore.map { "\($0)%" } ?? "—", title: "Average match",
                             symbol: "scope")
            }
            if insights.recentScores.count >= 2 {
                trendCard(insights)
            } else {
                Text("Finish a couple of shots from a shoot to see your match trend here.")
                    .font(PoserType.supporting)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PoserSpace.regular)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            milestonesSection(insights)
        }
    }

    private func progressFact(value: String, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PoserSpace.medium)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Milestones

    /// A grid, not a horizontal scroller, so it never fights the page swipe.
    private func milestonesSection(_ insights: ProfileInsights) -> some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Milestones").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(insights.earnedCount) of \(insights.milestones.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(insights.milestones) { milestone in
                    milestoneTile(milestone)
                }
            }
        }
    }

    private func milestoneTile(_ milestone: ProfileInsights.Milestone) -> some View {
        VStack(spacing: 6) {
            Image(systemName: milestone.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(milestone.isEarned ? Color.black : Palette.tertiaryText)
                .frame(width: 40, height: 40)
                .background(milestone.isEarned ? Color.white : Palette.elevated, in: Circle())
            Text(milestone.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(milestone.isEarned ? Palette.primaryText : Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(milestone.isEarned ? "Earned" : "\(milestone.progress)/\(milestone.goal)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PoserSpace.medium)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(milestone.title): \(milestone.detail). "
            + (milestone.isEarned ? "Earned." : "\(milestone.progress) of \(milestone.goal)."))
    }

    private func renderProfileCard() {
        let best = shootStore.shots
            .sorted { ($0.matchScore ?? -1, $0.createdAt) > ($1.matchScore ?? -1, $1.createdAt) }
            .prefix(3)
            .compactMap { shot -> ProfileCardRenderer.Tile? in
                guard let photo = shootStore.photoThumbnail(for: shot) else { return nil }
                return .init(photo: photo, reference: shootStore.referenceThumbnail(for: shot), score: shot.matchScore)
            }
        profileCard = ProfileCardRenderer.render(
            name: profileStore.profile.displayName, bio: profileStore.profile.bio,
            avatar: profileStore.avatarImage, initials: profileStore.initials,
            insights: insights, tiles: best)
    }

    // MARK: Tabs

    @ViewBuilder
    private var gallery: some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
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
                    ForEach(pinnedOrder) { shot in
                        if let photo = shootStore.photoThumbnail(for: shot) {
                            Button { onSelectShot(shot) } label: {
                                pairedTile(photo: photo, reference: shootStore.referenceThumbnail(for: shot),
                                           score: shot.matchScore)
                                    .overlay(alignment: .topTrailing) {
                                        if shot.id == pinnedShotID {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(6)
                                                .background(.black.opacity(0.6), in: Circle())
                                                .padding(5)
                                                .accessibilityLabel("Best shot")
                                        }
                                    }
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

    /// The best-scoring shot is pinned first, like a pinned post; the rest stay newest first.
    private var pinnedShotID: UUID? {
        guard shootStore.shots.count > 1 else { return nil }
        return shootStore.shots.filter { $0.matchScore != nil }
            .max { ($0.matchScore ?? 0, $0.createdAt) < ($1.matchScore ?? 0, $1.createdAt) }?.id
    }

    private var pinnedOrder: [CompletedShot] {
        guard let pinned = pinnedShotID, let shot = shootStore.shots.first(where: { $0.id == pinned }) else {
            return shootStore.shots
        }
        return [shot] + shootStore.shots.filter { $0.id != pinned }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.shots, symbol: "square.grid.3x3", title: "Shots")
            tabButton(.poses, symbol: "figure.stand", title: "Poses")
            tabButton(.progress, symbol: "chart.line.uptrend.xyaxis", title: "Progress")
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    private func tabButton(_ tab: ProfileTab, symbol: String, title: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { selectedTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Palette.primaryText : Palette.tertiaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Palette.primaryText : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// References this person recommends: their saved inspiration, shown for others to try.
    private var poses: some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            LazyVGrid(columns: columns, spacing: 10) {
                PhotosPicker(selection: $posePicks, maxSelectionCount: 10,
                             selectionBehavior: .ordered, matching: .images) {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                                Text("Add pose").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Palette.primaryText)
                        }
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add poses from your photos")

                ForEach(inspirationStore.items) { item in
                    if let image = inspirationStore.image(for: item) {
                        Button { onOpenReference(item) } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Try this pose")
                        .contextMenu {
                            Button("Try this pose", systemImage: "camera") { onOpenReference(item) }
                            Button("Remove from profile", systemImage: "trash", role: .destructive) {
                                onDeleteReference(item.id)
                            }
                        }
                    }
                }
            }
            if inspirationStore.items.isEmpty {
                Text("Add poses you love. They show here for you to try, and later for friends to see.")
                    .font(PoserType.supporting)
                    .foregroundStyle(Palette.secondaryText)
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
        ScrollView(showsIndicators: false) {
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

/// A story-sized (9:16) image of a profile, for sharing to Instagram or TikTok before accounts exist.
enum ProfileCardRenderer {
    struct Tile {
        let photo: UIImage
        let reference: UIImage?
        let score: Int?
    }

    static func render(name: String, bio: String?, avatar: UIImage?, initials: String,
                       insights: ProfileInsights, tiles: [Tile]) -> UIImage {
        let size = CGSize(width: 1080, height: 1920)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let gray = UIColor(white: 0.68, alpha: 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            draw("poser", font: .systemFont(ofSize: 64, weight: .bold), color: .white, kern: -2,
                 in: CGRect(x: 0, y: 120, width: size.width, height: 80), align: .center)

            // Avatar, with the streak ring when active.
            let avatarRect = CGRect(x: size.width / 2 - 150, y: 300, width: 300, height: 300)
            if insights.currentStreak > 0 {
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: avatarRect.insetBy(dx: -16, dy: -16))
                ring.lineWidth = 6
                ring.stroke()
            }
            cg.saveGState()
            UIBezierPath(ovalIn: avatarRect).addClip()
            UIColor(white: 0.14, alpha: 1).setFill()
            cg.fill(avatarRect)
            if let avatar {
                drawFilled(avatar, in: avatarRect)
            } else {
                draw(initials, font: .systemFont(ofSize: 110, weight: .bold), color: .white,
                     in: CGRect(x: avatarRect.minX, y: avatarRect.midY - 66, width: avatarRect.width, height: 132),
                     align: .center)
            }
            cg.restoreGState()

            var y: CGFloat = 660
            draw(name, font: .systemFont(ofSize: 60, weight: .bold), color: .white,
                 in: CGRect(x: 80, y: y, width: size.width - 160, height: 76), align: .center)
            y += 86
            if insights.currentStreak > 0 {
                draw("\(insights.currentStreak)-day streak", font: .systemFont(ofSize: 32, weight: .semibold),
                     color: .white, in: CGRect(x: 80, y: y, width: size.width - 160, height: 44), align: .center)
                y += 54
            }
            if let bio, !bio.isEmpty {
                let bioRect = CGRect(x: 120, y: y, width: size.width - 240, height: 132)
                draw(bio, font: .systemFont(ofSize: 34), color: gray, in: bioRect, align: .center, wraps: true)
                y += 150
            }

            // Stats row.
            y = max(y + 30, 1000)
            let stats = [("\(insights.shotCount)", "shots"),
                         (insights.bestMatch.map { "\($0)%" } ?? "—", "best match"),
                         ("\(insights.posesTried)", "poses tried")]
            let column = (size.width - 160) / 3
            for (index, stat) in stats.enumerated() {
                let x = 80 + CGFloat(index) * column
                draw(stat.0, font: .systemFont(ofSize: 84, weight: .bold), color: .white,
                     in: CGRect(x: x, y: y, width: column, height: 100), align: .center)
                draw(stat.1, font: .systemFont(ofSize: 30, weight: .medium), color: gray,
                     in: CGRect(x: x, y: y + 104, width: column, height: 40), align: .center)
            }

            // Top shots, each with its reference inset.
            let tileY = y + 230
            let gap: CGFloat = 20
            let tileWidth = (size.width - 120 - gap * 2) / 3
            let tileHeight = tileWidth * 4 / 3
            for (index, tile) in tiles.prefix(3).enumerated() {
                let rect = CGRect(x: 60 + CGFloat(index) * (tileWidth + gap), y: tileY,
                                  width: tileWidth, height: tileHeight)
                cg.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 28).addClip()
                drawFilled(tile.photo, in: rect)
                cg.restoreGState()
                if let reference = tile.reference {
                    let inset = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: rect.width * 0.38,
                                       height: rect.width * 0.38)
                    cg.saveGState()
                    let path = UIBezierPath(roundedRect: inset, cornerRadius: 14)
                    path.addClip()
                    drawFilled(reference, in: inset)
                    cg.restoreGState()
                    UIColor.black.setStroke()
                    path.lineWidth = 4
                    path.stroke()
                }
                if let score = tile.score {
                    let badge = CGRect(x: rect.maxX - 124, y: rect.maxY - 64, width: 112, height: 52)
                    UIColor(white: 0, alpha: 0.65).setFill()
                    UIBezierPath(roundedRect: badge, cornerRadius: 26).fill()
                    draw("\(score)%", font: .systemFont(ofSize: 30, weight: .bold), color: .white,
                         in: badge.offsetBy(dx: 0, dy: 8), align: .center)
                }
            }

            draw("Recreate the shot. Match the pose.", font: .systemFont(ofSize: 32, weight: .medium),
                 color: gray, in: CGRect(x: 0, y: size.height - 150, width: size.width, height: 44), align: .center)
        }
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, kern: CGFloat = 0,
                             in rect: CGRect, align: NSTextAlignment, wraps: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style,
        ]
        NSString(string: text).draw(with: rect, options: wraps ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                                                                : [.usesLineFragmentOrigin],
                                    attributes: attributes, context: nil)
    }

    private static func drawFilled(_ image: UIImage, in rect: CGRect) {
        let scale = max(rect.width / max(image.size.width, 1), rect.height / max(image.size.height, 1))
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height))
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
