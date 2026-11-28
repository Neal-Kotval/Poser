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
    @State private var avatarPicker: PhotosPickerItem?
    @State private var avatarDraft: AvatarDraft?
    @State private var avatarError: String?
    @State private var avatarVersion = 0
    @State private var profileCard: UIImage?
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ProfileTab: CaseIterable {
        case shots, poses, progress

        var title: String {
            switch self {
            case .shots: "Shots"
            case .poses: "Poses"
            case .progress: "Progress"
            }
        }

        var symbol: String {
            switch self {
            case .shots: "square.grid.3x3"
            case .poses: "figure.stand"
            case .progress: "chart.line.uptrend.xyaxis"
            }
        }
    }

    private let mediaColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private let milestoneColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var insights: ProfileInsights {
        ProfileInsights(shots: shootStore.shots, savedPoses: inspirationStore.items.count)
    }

    private var cardKey: String {
        let profile = profileStore.profile
        return [profile.displayName, profile.bio ?? "", "\(shootStore.shots.count)",
                "\(shootStore.bestMatch ?? -1)", "\(inspirationStore.items.count)",
                "\(insights.currentStreak)", shootStore.shots.first?.id.uuidString ?? "",
                "\(avatarVersion)"].joined(separator: "|")
    }

    var body: some View {
        let insights = self.insights
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header(insights)
                    .padding(.horizontal, PoserSpace.regular)
                    .padding(.top, PoserSpace.medium)
                    .padding(.bottom, PoserSpace.regular)

                tabBar

                switch selectedTab {
                case .shots:
                    gallery
                case .poses:
                    poses
                case .progress:
                    progress(insights)
                        .padding(.horizontal, PoserSpace.regular)
                        .padding(.top, PoserSpace.regular)
                }
            }
            .foregroundStyle(Palette.primaryText)
            .frame(maxWidth: 620)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .task(id: cardKey) { await renderProfileCard() }
        .task(id: shootStore.shots.count) { await shootStore.scoreMissingMatches() }
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
                    avatarVersion += 1
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

            VStack(alignment: .leading, spacing: PoserSpace.xSmall) {
                HStack(spacing: PoserSpace.small) {
                    Text(profileStore.profile.displayName)
                        .font(.system(.title3, design: .rounded, weight: .bold))
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
                } else {
                    headerButtonLabel("Share profile", symbol: "square.and.arrow.up")
                        .opacity(0.4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func headerButtonLabel(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(Palette.primaryText)
        .frame(maxWidth: .infinity, minHeight: 44)
        .poserGlass(cornerRadius: PoserRadius.control, interactive: true)
    }

    private func streakChip(_ days: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text("\(days)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(Palette.background)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Palette.primaryText, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days)-day shooting streak")
    }

    private func avatar(onStreak: Bool) -> some View {
        ZStack {
            if let image = profileStore.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(profileStore.initials)
                    .font(.system(.title, design: .rounded, weight: .bold))
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

    private func headerStat(value: String, title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
    }

    private func tabButton(_ tab: ProfileTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
                Text(tab.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Palette.primaryText : Palette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Palette.primaryText)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "profileTabIndicator", in: tabNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Shots Grid

    @ViewBuilder
    private var gallery: some View {
        if shootStore.shots.isEmpty {
            VStack(spacing: PoserSpace.regular) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Your shoots will live here")
                        .font(PoserType.title)
                        .foregroundStyle(Palette.primaryText)
                    Text("Take a shot from the camera tab to start your collection.")
                        .font(PoserType.supporting)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                Button(action: onOpenCamera) {
                    Label("Open camera", systemImage: "camera")
                        .font(PoserType.action)
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 48)
                        .background(Palette.primaryText, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PoserSpace.xLarge)
            .padding(.top, 64)
        } else {
            LazyVGrid(columns: mediaColumns, spacing: 2) {
                ForEach(pinnedOrder) { shot in
                    if let photo = shootStore.photoThumbnail(for: shot) {
                        Button { onSelectShot(shot) } label: {
                            shotGridTile(photo: photo, score: shot.matchScore, isPinned: shot.id == pinnedShotID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Shot from \(shot.createdAt.formatted(date: .abbreviated, time: .omitted))"
                            + (shot.matchScore.map { ", \($0) percent match" } ?? "")
                            + (shot.id == pinnedShotID ? ", pinned best shot" : ""))
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func shotGridTile(photo: UIImage, score: Int?, isPinned: Bool) -> some View {
        GeometryReader { tile in
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: tile.size.width, height: tile.size.height)
                .clipped()
                .overlay(alignment: .bottom) {
                    if score != nil {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 44)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let score {
                        Text("\(score)%")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(6)
                    }
                }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .background(Palette.surface)
        .contentShape(Rectangle())
    }

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

    // MARK: Poses Grid

    private var poses: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inspirationStore.items.isEmpty {
                VStack(spacing: PoserSpace.regular) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("No saved poses yet")
                            .font(PoserType.title)
                            .foregroundStyle(Palette.primaryText)
                        Text("Add poses you love so they are one tap away when you shoot.")
                            .font(PoserType.supporting)
                            .foregroundStyle(Palette.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    PhotosPicker(selection: $posePicks, maxSelectionCount: 10,
                                 selectionBehavior: .ordered, matching: .images) {
                        Label("Add poses", systemImage: "plus")
                            .font(PoserType.action)
                            .foregroundStyle(Palette.background)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 48)
                            .background(Palette.primaryText, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PoserSpace.xLarge)
                .padding(.top, 64)
            } else {
                HStack(spacing: PoserSpace.small) {
                    Text("\(inspirationStore.items.count) \(inspirationStore.items.count == 1 ? "pose" : "poses")")
                        .font(PoserType.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    PhotosPicker(selection: $posePicks, maxSelectionCount: 10,
                                 selectionBehavior: .ordered, matching: .images) {
                        Label("Add pose", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .poserGlass(cornerRadius: 18, interactive: true)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add poses from your photos")
                }
                .padding(.horizontal, PoserSpace.regular)
                .padding(.vertical, 4)

                LazyVGrid(columns: mediaColumns, spacing: 2) {
                    ForEach(inspirationStore.items) { item in
                        if let image = inspirationStore.image(for: item) {
                            Button { onOpenReference(item) } label: {
                                GeometryReader { tile in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: tile.size.width, height: tile.size.height)
                                        .clipped()
                                }
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .background(Palette.surface)
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
            }
        }
    }

    // MARK: Progress

    private func progress(_ insights: ProfileInsights) -> some View {
        VStack(alignment: .leading, spacing: PoserSpace.large) {
            HStack(spacing: 0) {
                progressStatColumn(value: "\(insights.currentStreak)", title: "Day streak", symbol: "flame.fill")
                Rectangle().fill(Palette.border).frame(width: 1, height: 36)
                progressStatColumn(value: "\(insights.longestStreak)", title: "Longest", symbol: "calendar")
                Rectangle().fill(Palette.border).frame(width: 1, height: 36)
                progressStatColumn(value: insights.averageScore.map { "\($0)%" } ?? "—", title: "Avg match",
                                   symbol: "scope")
            }
            .padding(.vertical, PoserSpace.regular)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous)
                .stroke(Palette.border, lineWidth: 1))

            if insights.recentScores.count >= 2 {
                trendCard(insights)
            } else {
                Text("Finish a couple of shots from a shoot to see your match trend here.")
                    .font(PoserType.supporting)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PoserSpace.regular)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1))
            }

            milestonesSection(insights)
        }
    }

    private func progressStatColumn(value: String, title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func trendCard(_ insights: ProfileInsights) -> some View {
        let points = Array(insights.recentScores.enumerated())
        return VStack(alignment: .leading, spacing: PoserSpace.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Match trend").font(.subheadline.weight(.semibold))
                Spacer()
                Text(insights.trendHeadline)
                    .font(.caption.weight(.medium))
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
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
            .frame(height: 116)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Match trend over your last \(points.count) scored shots. \(insights.trendHeadline).")
        }
        .padding(PoserSpace.regular)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous)
            .stroke(Palette.border, lineWidth: 1))
    }

    private func milestonesSection(_ insights: ProfileInsights) -> some View {
        VStack(alignment: .leading, spacing: PoserSpace.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Milestones").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(insights.earnedCount) of \(insights.milestones.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
            }
            LazyVGrid(columns: milestoneColumns, spacing: 10) {
                ForEach(insights.milestones) { milestone in
                    milestoneTile(milestone)
                }
            }
        }
    }

    private func milestoneTile(_ milestone: ProfileInsights.Milestone) -> some View {
        VStack(spacing: 6) {
            Image(systemName: milestone.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(milestone.isEarned ? Palette.background : Palette.tertiaryText)
                .frame(width: 40, height: 40)
                .background(milestone.isEarned ? Palette.primaryText : Palette.elevated, in: Circle())
            Text(milestone.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(milestone.isEarned ? Palette.primaryText : Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(milestone.isEarned ? "Earned" : "\(milestone.progress)/\(milestone.goal)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PoserSpace.medium)
        .padding(.horizontal, 6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(milestone.isEarned ? Color.white.opacity(0.22) : Palette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(milestone.title): \(milestone.detail). "
            + (milestone.isEarned ? "Earned." : "\(milestone.progress) of \(milestone.goal)."))
    }

    private func renderProfileCard() async {
        let name = profileStore.profile.displayName
        let bio = profileStore.profile.bio
        let avatar = profileStore.avatarImage
        let initials = profileStore.initials
        let snapshot = insights
        let tiles = shootStore.shots
            .sorted { ($0.matchScore ?? -1, $0.createdAt) > ($1.matchScore ?? -1, $1.createdAt) }
            .prefix(3)
            .compactMap { shot -> ProfileCardRenderer.Tile? in
                guard let photo = shootStore.photoThumbnail(for: shot) else { return nil }
                return .init(photo: photo, reference: shootStore.referenceThumbnail(for: shot), score: shot.matchScore)
            }
        let rendered = await Task.detached(priority: .utility) {
            ProfileCardRenderer.render(
                name: name, bio: bio,
                avatar: avatar, initials: initials,
                insights: snapshot, tiles: tiles)
        }.value
        guard !Task.isCancelled else { return }
        profileCard = rendered
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PoserSpace.large) {
            ZStack {
                Text("Edit profile")
                    .font(.headline.weight(.semibold))
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    Spacer()
                    Button { onSave(name, bio) } label: {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canSave ? Palette.background : Palette.tertiaryText)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(canSave ? Palette.primaryText : Palette.elevated, in: Capsule())
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: PoserSpace.regular) {
                    field("Name", count: name.count, limit: UserProfile.nameLimit) {
                        TextField("Your name", text: $name)
                            .font(PoserType.body)
                            .textInputAutocapitalization(.words)
                            .onChange(of: name) { _, value in
                                let clean = value.replacingOccurrences(of: "\n", with: " ")
                                let limited = String(clean.prefix(UserProfile.nameLimit))
                                if limited != value { name = limited }
                            }
                    }
                    field("Bio", count: bio.count, limit: UserProfile.bioLimit) {
                        TextField("Tell people about you", text: $bio, axis: .vertical)
                            .font(PoserType.body)
                            .lineLimit(3...6)
                            .onChange(of: bio) { _, value in
                                if value.count > UserProfile.bioLimit { bio = String(value.prefix(UserProfile.bioLimit)) }
                            }
                    }
                    Text("Your profile stays on this phone. No account is required.")
                        .font(PoserType.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.top, PoserSpace.xSmall)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, PoserSpace.regular)
        .padding(.top, PoserSpace.medium)
        .foregroundStyle(Palette.primaryText)
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
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1))
        }
    }
}

struct ShotFeedView: View {
    let startShotID: UUID
    @ObservedObject var shootStore: ShootStore
    @ObservedObject var profileStore: UserProfileStore
    let onClose: () -> Void

    @State private var commentsShotID: CommentsTarget?
    @State private var message: String?

    private struct CommentsTarget: Identifiable {
        let id: UUID
    }

    private var shot: CompletedShot? {
        shootStore.shots.first { $0.id == startShotID }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            if let shot {
                ShotPostCard(shot: shot, shootStore: shootStore, profileStore: profileStore,
                             onComments: { commentsShotID = CommentsTarget(id: shot.id) },
                             onError: { message = $0 })
                    .frame(maxWidth: 620)
                    .padding(.top, PoserSpace.xSmall)
                    .padding(.bottom, PoserSpace.xLarge)
                    .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                Text("Post")
                    .font(.headline.weight(.semibold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                            .frame(width: 44, height: 44)
                            .poserGlass(cornerRadius: 22, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                }
            }
            .padding(.horizontal, PoserSpace.regular)
            .padding(.top, PoserSpace.small)
            .padding(.bottom, PoserSpace.medium)
            .background(
                LinearGradient(
                    colors: [Palette.background, Palette.background.opacity(0.92), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )
        }
        .foregroundStyle(Palette.primaryText)
        .background(Palette.background.ignoresSafeArea())
        .onChange(of: shot == nil) { _, isRemoved in
            if isRemoved { onClose() }
        }
        .sheet(item: $commentsShotID) { target in
            ShotCommentsSheet(shotID: target.id, shootStore: shootStore, profileStore: profileStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Poser", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct ShotPostCard: View {
    let shot: CompletedShot
    @ObservedObject var shootStore: ShootStore
    @ObservedObject var profileStore: UserProfileStore
    let onComments: () -> Void
    let onError: (String) -> Void

    @State private var photo: UIImage?
    @State private var reference: UIImage?
    @State private var shareCard: UIImage?
    @State private var viewerStart: ViewerStart?
    @State private var burstHeart = false
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ViewerStart: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private var pages: [ShotPhotoViewer.Page] {
        var pages: [ShotPhotoViewer.Page] = []
        if let reference { pages.append(.init(image: reference, label: "REFERENCE")) }
        if let photo { pages.append(.init(image: photo, label: "MY SHOT")) }
        return pages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PoserSpace.small) {
            header
                .padding(.horizontal, PoserSpace.regular)
            images
                .padding(.horizontal, 6)
            actionRow
                .padding(.horizontal, PoserSpace.regular)
            details
                .padding(.horizontal, PoserSpace.regular)
        }
        .task(id: shot.id) {
            let loadedPhoto = shootStore.photo(for: shot)
            let loadedReference = shootStore.reference(for: shot)
            photo = loadedPhoto
            reference = loadedReference
            if let loadedPhoto, let loadedReference {
                let score = shot.matchScore
                let rendered = await Task.detached(priority: .utility) {
                    ShareCardRenderer.render(reference: loadedReference, shot: loadedPhoto, score: score)
                }.value
                guard !Task.isCancelled else { return }
                shareCard = rendered
            }
        }
        .fullScreenCover(item: $viewerStart) { start in
            ShotPhotoViewer(pages: pages, startIndex: start.index)
        }
        .confirmationDialog("Delete this shot?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete shot", role: .destructive) {
                do { try withAnimation { try shootStore.remove(shot) } }
                catch { onError("This shot could not be deleted. Try again.") }
            }
        } message: {
            Text("It's removed from Poser. Your Photos library is unchanged.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProfileAvatarBadge(profileStore: profileStore, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(profileStore.profile.displayName)
                    .font(.subheadline.weight(.semibold))
                if let score = shot.matchScore {
                    Text("\(score)% match")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .monospacedDigit()
                }
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private var images: some View {
        HStack(spacing: 4) {
            if pages.isEmpty {
                Color.clear.aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                postImage(page.image, label: page.label) { viewerStart = ViewerStart(index: index) }
            }
        }
        .overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: 88))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 12)
                .scaleEffect(reduceMotion ? 1 : (burstHeart ? 1 : 0.4))
                .opacity(burstHeart ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var actionRow: some View {
        HStack(spacing: PoserSpace.small) {
            Button { toggleLike() } label: {
                Image(systemName: shot.isLiked ? "heart.fill" : "heart")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(shot.isLiked ? Color.pink : Palette.primaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: shot.isLiked)
                    .symbolEffectsRemoved(reduceMotion)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shot.isLiked ? "Unlike" : "Like")
            .accessibilityAddTraits(shot.isLiked ? [.isSelected] : [])

            Button(action: onComments) {
                Image(systemName: "bubble.right")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Palette.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Comments")

            if let shareCard {
                ShareLink(item: Image(uiImage: shareCard),
                          preview: SharePreview("My Poser shot", image: Image(uiImage: shareCard))) {
                    Image(systemName: "paperplane")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Palette.primaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
            Spacer()
        }
        .padding(.horizontal, -10)
        .padding(.vertical, -6)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(shot.likeCount == 1 ? "1 like" : "\(shot.likeCount) likes")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            ForEach(shot.commentList.suffix(2)) { comment in
                (Text(comment.author).fontWeight(.semibold) + Text(" ") + Text(comment.text))
                    .font(.subheadline)
                    .lineLimit(2)
            }
            if shot.commentList.count > 2 {
                Button("View all \(shot.commentList.count) comments", action: onComments)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            } else if shot.commentList.isEmpty {
                Button("Add a comment…", action: onComments)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(shot.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(Palette.tertiaryText)
        }
    }

    private func toggleLike() {
        do {
            try withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                try shootStore.toggleLike(shot.id)
            }
        } catch {
            onError("This like could not be saved. Try again.")
        }
    }

    private func doubleTapLike() {
        if !shot.isLiked { toggleLike() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.18)) { burstHeart = true }
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { burstHeart = true }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { burstHeart = false }
        }
    }

    private func postImage(_ image: UIImage, label: String, onOpen: @escaping () -> Void) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { Image(uiImage: image).resizable().scaledToFill() }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture(count: 2) { doubleTapLike() }
            .onTapGesture { onOpen() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label == "REFERENCE" ? "Reference photo" : "My shot")
            .accessibilityHint("Opens full screen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Like") { if !shot.isLiked { toggleLike() } }
    }

    private func save(_ photo: UIImage) {
        PhotoLibrarySaver.save(photo) { success in
            onError(success ? "Your shot is in Photos." : "Allow Photos access in Settings to save this shot.")
        }
    }
}

/// A post's comments with a composer, shown as a sheet like Instagram's comments.
struct ShotCommentsSheet: View {
    let shotID: UUID
    @ObservedObject var shootStore: ShootStore
    @ObservedObject var profileStore: UserProfileStore

    @State private var draft = ""
    @State private var message: String?
    @FocusState private var composing: Bool

    private var comments: [ShotComment] {
        shootStore.shots.first { $0.id == shotID }?.commentList ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Comments")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 22)
                .padding(.bottom, PoserSpace.medium)
            Divider().overlay(Palette.border)
            ScrollView(showsIndicators: false) {
                if comments.isEmpty {
                    VStack(spacing: 6) {
                        Text("No comments yet")
                            .font(.system(size: 20, weight: .bold))
                        Text("Start the conversation.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                } else {
                    LazyVStack(alignment: .leading, spacing: PoserSpace.regular) {
                        ForEach(comments) { comment in commentRow(comment) }
                    }
                    .padding(PoserSpace.regular)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            composer
        }
        .foregroundStyle(.white)
        .background(Palette.background.ignoresSafeArea())
        .alert("Poser", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func commentRow(_ comment: ShotComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileAvatarBadge(profileStore: profileStore, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.system(size: 13, weight: .semibold))
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryText)
                }
                Text(comment.text)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = comment.text }
            Button("Delete comment", systemImage: "trash", role: .destructive) {
                do { try withAnimation { try shootStore.removeComment(comment.id, from: shotID) } }
                catch { message = "This comment could not be deleted. Try again." }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Touch and hold to copy or delete")
    }

    private var composer: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .bottom, spacing: 10) {
            ProfileAvatarBadge(profileStore: profileStore, size: 34)
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .focused($composing)
                .onChange(of: draft) { _, new in
                    if new.count > ShotComment.limit { draft = String(new.prefix(ShotComment.limit)) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button("Post") { post() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(trimmed.isEmpty ? Palette.tertiaryText : .white)
                .disabled(trimmed.isEmpty)
                .frame(minWidth: 44, minHeight: 38)
        }
        .padding(.horizontal, PoserSpace.regular)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func post() {
        do {
            try withAnimation {
                _ = try shootStore.addComment(draft, author: profileStore.profile.displayName, to: shotID)
            }
            draft = ""
        } catch {
            message = "This comment could not be posted. Try again."
        }
    }
}

/// The profile photo, or initials when there isn't one, as a small circle.
struct ProfileAvatarBadge: View {
    @ObservedObject var profileStore: UserProfileStore
    let size: CGFloat

    var body: some View {
        Group {
            if let image = profileStore.avatarImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(profileStore.initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.elevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Full-screen, uncropped view of a post's photos. Swipe between reference and shot,
/// pinch or double-tap to zoom, and swipe down to close.
struct ShotPhotoViewer: View {
    struct Page {
        let image: UIImage
        let label: String
    }

    let pages: [Page]
    @State private var index: Int
    @State private var zoomed = false
    @State private var dismissDrag: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(pages: [Page], startIndex: Int) {
        self.pages = pages
        _index = State(initialValue: min(max(startIndex, 0), max(pages.count - 1, 0)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(1 - min(abs(dismissDrag) / 400, 0.6))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                    ZoomableImage(image: page.image, zoomed: $zoomed)
                        .tag(offset)
                        .accessibilityLabel(page.label == "REFERENCE" ? "Reference photo" : "My shot")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .offset(y: dismissDrag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !zoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                        dismissDrag = value.translation.height
                    }
                    .onEnded { value in
                        guard !zoomed else { return }
                        if abs(value.translation.height) > 140 || abs(value.predictedEndTranslation.height) > 320 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dismissDrag = 0 }
                        }
                    }
            )

            HStack {
                if pages.indices.contains(index) {
                    Text(pages[index].label)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, PoserSpace.regular)
            .opacity(dismissDrag == 0 ? 1 : 0)
        }
        .statusBarHidden()
        .onChange(of: index) { _, _ in zoomed = false }
    }
}

/// Fits the whole photo on screen; pinch or double-tap zooms, and dragging pans while zoomed.
private struct ZoomableImage: View {
    let image: UIImage
    @Binding var zoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(committedScale * value.magnification, 1), 5)
                        }
                        .onEnded { _ in
                            committedScale = scale
                            if scale <= 1.01 { reset() } else { zoomed = true }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = clamp(CGSize(width: committedOffset.width + value.translation.width,
                                                  height: committedOffset.height + value.translation.height),
                                           in: geo.size)
                        }
                        .onEnded { _ in committedOffset = offset },
                    including: scale > 1 ? .all : .subviews
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if scale > 1 { reset() } else {
                            scale = 2.5
                            committedScale = 2.5
                            zoomed = true
                        }
                    }
                }
        }
        .onChange(of: zoomed) { _, isZoomed in
            if !isZoomed && scale != 1 { reset() }
        }
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
        zoomed = false
    }

    private func clamp(_ proposed: CGSize, in container: CGSize) -> CGSize {
        let maxX = container.width * (scale - 1) / 2
        let maxY = container.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
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
            reference.drawFilled(in: CGRect(x: margin, y: y, width: width, height: height), cornerRadius: 28, context: context.cgContext)
            shot.drawFilled(in: CGRect(x: margin + width + gap, y: y, width: width, height: height), cornerRadius: 28, context: context.cgContext)

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
}

/// A story-sized (9:16) image of a profile, for sharing to Instagram or TikTok before accounts exist.
enum ProfileCardRenderer {
    struct Tile: Sendable {
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
                avatar.drawFilled(in: avatarRect)
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
                tile.photo.drawFilled(in: rect, cornerRadius: 28, context: cg)
                if let reference = tile.reference {
                    let inset = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: rect.width * 0.38,
                                       height: rect.width * 0.38)
                    cg.saveGState()
                    let path = UIBezierPath(roundedRect: inset, cornerRadius: 14)
                    path.addClip()
                    reference.drawFilled(in: inset)
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
}

private extension UIImage {
    func drawFilled(in rect: CGRect, cornerRadius: CGFloat? = nil, context: CGContext? = nil) {
        if let cornerRadius, let context {
            context.saveGState()
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
        }
        let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                        width: drawn.width, height: drawn.height))
        if cornerRadius != nil, let context {
            context.restoreGState()
        }
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
