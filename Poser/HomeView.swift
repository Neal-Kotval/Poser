import SwiftUI
import PhotosUI

private struct ReferenceTagFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

enum HomePaging {
    static func allowsSwipe(start: CGPoint, translation: CGSize, excluding frame: CGRect) -> Bool {
        !frame.contains(start) && abs(translation.width) > abs(translation.height)
    }
}

struct HomeView: View {
    private enum Tab: Int, CaseIterable { case home, camera, profile }

    @State private var activeTab: Tab = .camera
    @StateObject private var inspirationStore = InspirationStore()
    @StateObject private var shootStore = ShootStore()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var referenceImage: UIImage?
    @State private var analysis: PhotoAnalysis?
    @State private var selectedRecipe: ShotRecipe?
    @State private var capturedImage: UIImage?
    @State private var showingLink = false
    @State private var showingScan = false
    @State private var showingPoseTutorial = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var isSceneScan = false
    @State private var comparisonNote: String?
    @State private var poseScore: Int?
    @State private var scannedScene: UIImage?
    @State private var sceneMatches: [SceneMatch] = []
    @State private var selectedMatches: Set<UUID> = []
    @State private var shootQueue: [UUID] = []
    @State private var currentShotIndex = 0
    @State private var isPreparingReference = false
    @State private var isSavingShot = false
    @State private var selectedCompletedShot: CompletedShot?
    @State private var flowID = UUID()
    @State private var showLiveCamera = true
    @State private var showShotDetails = false
    @State private var selectedReferenceTag: ReferenceTag?
    @State private var referenceTagFrame: CGRect = .null
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.25)))
    private var pageDragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            pagePager
            .background(Palette.background.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if !showingPoseTutorial { bottomBar }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .overlay {
            if showingPoseTutorial, let selectedRecipe {
                PoseTutorialView(analysis: analysis, recipe: selectedRecipe) {
                    withAnimation(.easeInOut(duration: 0.45)) { showingPoseTutorial = false }
                } onClose: {
                    withAnimation(.easeInOut(duration: 0.45)) { showingPoseTutorial = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            let requestID = flowID
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { throw AnalysisError.invalidImage }
                    guard requestID == flowID else { return }
                    await importInspiration(image, source: .photoLibrary, imageData: data)
                    selectedPhoto = nil
                } catch {
                    if requestID == flowID { errorMessage = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showingLink) {
            LinkEntryView { image in
                showingLink = false
                Task { await importInspiration(image, source: .link) }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showingScan) {
            CameraScreen(mode: .scan, recipe: nil, targetX: 0.5) { image in
                Task { await scanScene(image) }
            }
        }
        .sheet(item: $selectedCompletedShot) { shot in
            completedShotDetail(shot)
        }
        .alert("Could not continue", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Photo saved", isPresented: Binding(
            get: { savedMessage != nil },
            set: { if !$0 { savedMessage = nil } }
        )) {
            Button("OK", role: .cancel) { savedMessage = nil }
        } message: { Text(savedMessage ?? "") }
    }

    private var pagePager: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                homePage.frame(width: geometry.size.width)
                cameraPage.frame(width: geometry.size.width)
                profilePage.frame(width: geometry.size.width)
            }
            .offset(x: -CGFloat(activeTab.rawValue) * geometry.size.width + pageDragOffset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: activeTab)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .named("homePager"))
                    .updating($pageDragOffset) { value, offset, _ in
                        let excludedFrame = activeTab == .home ? referenceTagFrame : .null
                        guard HomePaging.allowsSwipe(start: value.startLocation,
                                                     translation: value.translation,
                                                     excluding: excludedFrame) else { return }
                        let translation = value.translation.width
                        guard !(activeTab == .home && translation > 0),
                              !(activeTab == .profile && translation < 0) else { return }
                        offset = translation
                    }
                    .onEnded { value in
                        let excludedFrame = activeTab == .home ? referenceTagFrame : .null
                        guard HomePaging.allowsSwipe(start: value.startLocation,
                                                     translation: value.translation,
                                                     excluding: excludedFrame),
                              abs(value.translation.width) > 50 else { return }
                        let step = value.translation.width < 0 ? 1 : -1
                        if let next = Tab(rawValue: activeTab.rawValue + step) {
                            activeTab = next
                        }
                    }
            )
        }
        .coordinateSpace(name: "homePager")
        .onPreferenceChange(ReferenceTagFrameKey.self) { referenceTagFrame = $0 }
    }

    @ViewBuilder
    private var cameraPage: some View {
        if showLiveCamera {
            CameraScreen(
            mode: .guide,
            recipe: selectedRecipe,
            targetX: analysis?.subjectPoint?.x ?? 0.5,
            targetPose: analysis?.poseSkeleton,
            shotGeometry: analysis?.geometry,
            shotSpec: analysis?.geometry.spec,
            referenceImage: selectedRecipe == nil ? nil : referenceImage,
            referenceTitle: shootQueue.isEmpty ? nil : matchingTitle(for: shootQueue[currentShotIndex]),
            queueProgress: shootQueue.isEmpty ? nil : (currentShotIndex + 1, shootQueue.count),
            embedded: true,
            isActive: activeTab == .camera,
            isGuideOverlayVisible: showingPoseTutorial
        ) { image in
            if !shootQueue.isEmpty {
                capturedImage = image
                comparisonNote = nil
                poseScore = nil
                withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = false }
                Task { await compare(image) }
            } else if selectedRecipe != nil, referenceImage != nil {
                capturedImage = image
                comparisonNote = nil
                poseScore = nil
                withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = false }
                Task { await compare(image) }
            } else {
                Task { await scanScene(image) }
            }
        } onPoseGuide: {
            openPoseGuide()
        } onStartOver: {
            reset()
        }
        } else {
            shootPage
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                landing
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, PoserSpace.large)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
    }

    private var shootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let capturedImage {
                    comparison(capturedImage)
                } else if isAnalyzing || isPreparingReference {
                    analyzingView
                } else if !sceneMatches.isEmpty && shootQueue.isEmpty {
                    sceneMatchResults
                } else if let selectedRecipe {
                    recipeDetail(selectedRecipe)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Couldn’t prepare this shot")
                            .font(.system(size: 24, weight: .semibold))
                        Text("Choose another idea from Home or start a new scan.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.secondaryText)
                        Button("Browse Home") {
                            withAnimation(.easeOut(duration: 0.32)) { activeTab = .home }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 8)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 70)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, PoserSpace.large)
            .padding(.bottom, 180)
            .frame(maxWidth: .infinity)
        }
        .id(capturedImage == nil ? "shot-plan" : "shot-review")
        .background(Palette.background)
    }

    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("My shots")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                    Text("\(shootStore.shots.count) completed")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                }
                .padding(.top, PoserSpace.large)
                if shootStore.shots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your shoots will live here")
                            .font(.system(size: 19, weight: .semibold))
                        Text("Take your first shot to start a collection.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondaryText)
                        Button("Open camera") {
                            withAnimation(.easeOut(duration: 0.32)) { activeTab = .camera }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 8)
                    }
                    .padding(.top, 36)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(shootStore.shots) { shot in
                            if let photo = shootStore.photo(for: shot) {
                                Button { selectedCompletedShot = shot } label: {
                                    GeometryReader { tile in
                                        Image(uiImage: photo)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: tile.size.width, height: tile.size.height)
                                            .clipped()
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Completed shot from \(shot.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if activeTab == .camera, !showLiveCamera, !sceneMatches.isEmpty, shootQueue.isEmpty, capturedImage == nil {
                Button { Task { await startSelectedShoot() } } label: {
                    Text(isPreparingReference ? "Preparing your shots…" : "Continue with \(selectedMatches.count) \(selectedMatches.count == 1 ? "shot" : "shots")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                }
                .buttonStyle(.plain)
                .disabled(selectedMatches.isEmpty || isPreparingReference)
                .opacity(selectedMatches.isEmpty ? 0.4 : 1)
                .padding(.horizontal, PoserSpace.large)
                .padding(.top, 10)
            }
            HStack(spacing: 4) {
                navigationItem(.home, title: "Home", symbol: "house", selectedSymbol: "house.fill")
                navigationItem(.camera, title: "Camera", symbol: "camera", selectedSymbol: "camera.fill")
                navigationItem(.profile, title: "Profile", symbol: "person.crop.circle", selectedSymbol: "person.crop.circle.fill")
            }
            .padding(6)
            .poserGlass(cornerRadius: 36)
            .frame(maxWidth: 420)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private func navigationItem(_ tab: Tab, title: String, symbol: String, selectedSymbol: String) -> some View {
        let selected = activeTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.32)) { activeTab = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedSymbol : symbol)
                    .font(.system(size: 21, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? .white : Palette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.white.opacity(selected ? 0.16 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var header: some View {
        ZStack {
            Text("poser")
                .font(PoserType.wordmark)
                .tracking(-1.5)
                .foregroundStyle(.white)
            HStack {
                Spacer()
                if activeTab == .camera, !showLiveCamera {
                    Button("Start over") { reset() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .frame(height: 40)
    }

    private var landing: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Find your next shot")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.7)
                .foregroundStyle(.white)

            HStack(spacing: 9) {
                Button { showingScan = true } label: {
                    feedAction(symbol: "viewfinder", title: "Scan place")
                }
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    feedAction(symbol: "plus", title: "Add photo")
                }
                Button { showingLink = true } label: {
                    feedAction(symbol: "link", title: "Paste link")
                }
            }
            .buttonStyle(.plain)

            if !inspirationStore.items.isEmpty {
                savedInspiration
            }

            HStack {
                Text("For you")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(ReferenceCatalog.items(matching: selectedReferenceTag).count) photos")
                    .font(PoserType.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            referenceTagBar
                .padding(.top, -12)

            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(ReferenceCatalog.items(matching: selectedReferenceTag)) { asset in
                    if let image = asset.preview {
                        feedCard(asset, image: image)
                    }
                }
            }
        }
    }

    private var referenceTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: PoserSpace.small) {
                    referenceTagButton(nil)
                    ForEach(ReferenceCatalog.tags) { tag in
                        referenceTagButton(tag)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("referenceTagBar")
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReferenceTagFrameKey.self,
                                       value: geometry.frame(in: .named("homePager")))
            }
        }
    }

    private func referenceTagButton(_ tag: ReferenceTag?) -> some View {
        let isSelected = selectedReferenceTag == tag
        return Button {
            selectedReferenceTag = tag
        } label: {
            Text(tag?.title ?? "All")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, PoserSpace.regular)
                .frame(minHeight: 44)
                .foregroundStyle(isSelected ? Palette.background : Palette.primaryText)
                .poserGlass(cornerRadius: 100, interactive: true,
                            tint: isSelected ? .white.opacity(0.9) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(tag == nil ? "Show all reference photos" : "Filter reference photos by \(tag!.title)")
    }

    private func feedAction(symbol: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 44)
        .poserGlass(interactive: true)
    }

    private func feedCard(_ asset: ReferenceAsset, image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                if let data = asset.imageData, let fullImage = UIImage(data: data) {
                    Task { await analyze(fullImage, scene: false, imageData: data) }
                }
            } label: {
                GeometryReader { tile in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tile.size.width, height: tile.size.height)
                        .clipped()
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                // Cropping the image does not constrain its hit-testing area.
                // Keep the photo button inside its visible tile, away from the filters.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(asset.title) inspiration")

            HStack(alignment: .center) {
                Text(asset.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let source = asset.source {
                    Link(destination: source) {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel("Open original Pin")
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface, style: .continuous))
    }

    @ViewBuilder
    private var savedInspiration: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Your inspiration")
                    .font(PoserType.title)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(inspirationStore.items.count) saved")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }
            if inspirationStore.items.isEmpty {
                Text("Photos you import will appear here for future shoots and scene matching.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(inspirationStore.items) { item in
                            if let image = inspirationStore.image(for: item) {
                                Button {
                                    Task {
                                        let original = inspirationStore.originalData(for: item)
                                        await analyze(original.flatMap(UIImage.init(data:)) ?? image,
                                                      scene: false, imageData: original)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 132, height: 132)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                                        Text(item.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 132, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sceneMatchResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose your shots")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(selectedMatches.count) selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            if let scannedScene {
                HStack(alignment: .top, spacing: 14) {
                    Image(uiImage: scannedScene)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .clipped()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YOUR SCENE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 18) {
                ForEach(sceneMatches) { match in
                    if let image = matchingImage(for: match.id) {
                        Button {
                            if selectedMatches.contains(match.id) { selectedMatches.remove(match.id) }
                            else { selectedMatches.insert(match.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                GeometryReader { tile in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: tile.size.width, height: tile.size.height)
                                        .clipped()
                                }
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selectedMatches.contains(match.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24, weight: .medium))
                                            .shadow(radius: 3)
                                            .padding(10)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                                Text(matchingTitle(for: match.id))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(matchingTitle(for: match.id)), \(Int(match.score * 100)) percent match, \(selectedMatches.contains(match.id) ? "selected" : "not selected")")
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        Color.white.opacity(0.16)
            .frame(height: 1)
            .padding(.leading, 40)
    }

    private var analyzingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView().tint(.white)
            Text(isPreparingReference ? "Preparing your shot" : "Reading your photo")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(isPreparingReference ? "Finding the setup for your reference." : "Finding the subject, framing, and light.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 70)
    }

    private func recipeDetail(_ recipe: ShotRecipe) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(.white)
                Text(recipe.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if let referenceImage {
                GeometryReader { tile in
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: tile.size.width, height: tile.size.height)
                        .background(Palette.surface)
                        .overlay(alignment: .topLeading) {
                            imageLabel(isSceneScan ? "YOUR SCENE" : "REFERENCE")
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
            }
            VStack(spacing: 0) {
                instruction(symbol: "iphone", title: "Camera", body: analysis?.geometry.distanceLabel ?? recipe.camera)
                rowDivider
                instruction(symbol: "figure.stand", title: "Pose", body: analysis.map { $0.poseSkeleton?.shortCue ?? "Pose not measured; use the photo as your guide." } ?? recipe.pose)
            }
            Button {
                openPoseGuide()
            } label: {
                Text("See pose guide")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
            }
            .buttonStyle(.plain)
            DisclosureGroup("More setup details", isExpanded: $showShotDetails) {
                VStack(spacing: 0) {
                    instruction(symbol: "sun.max", title: "Light", body: analysis == nil ? recipe.light : "Match the light direction in the reference.")
                    rowDivider
                    instruction(symbol: "square.dashed", title: "Frame", body: analysis == nil ? recipe.framing : "Place the subject where they appear in the reference.")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.secondaryText)
        }
    }

    private func instruction(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(body).font(.system(size: 14)).foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 17)
    }

    private func comparison(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !shootQueue.isEmpty {
                Text("Shot \(currentShotIndex + 1) of \(shootQueue.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(shootQueue.isEmpty ? "Your shot" : "Review your shot")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let comparisonNote {
                Text(comparisonNote)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.58))
            }
            if let poseScore {
                HStack {
                    Text("Pose match")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("\(poseScore)%")
                        .font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.control))
            }
            if let referenceImage {
                GeometryReader { geometry in
                    let tileWidth = max(1, (geometry.size.width - 8) / 2)
                    HStack(spacing: 8) {
                        compareImage(referenceImage, label: isSceneScan ? "SCENE" : "REFERENCE",
                                     width: tileWidth, height: tileWidth)
                        compareImage(image, label: "YOUR SHOT", width: tileWidth, height: tileWidth)
                    }
                }
                .aspectRatio(2, contentMode: .fit)
            } else {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, 260)
                    compareImage(image, label: "YOUR SHOT", width: side, height: side)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 260)
            }
            if !shootQueue.isEmpty {
                Button {
                    Task { await completeCurrentShot(image) }
                } label: {
                    Text(isSavingShot ? "Saving shot…" : currentShotIndex + 1 < shootQueue.count ? "Use shot and continue" : "Use shot and finish")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                }
                .buttonStyle(.plain)
                .disabled(isSavingShot)
                Button("Retake") {
                    capturedImage = nil
                    comparisonNote = nil
                    poseScore = nil
                    withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = true; activeTab = .camera }
                }
                .disabled(isSavingShot)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                Button {
                    PhotoLibrarySaver.save(image) { success in
                        savedMessage = success ? "Your shot is in Photos." : "Allow Photos access in Settings to save this shot."
                    }
                } label: {
                    Text("Save to Photos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                }
                .buttonStyle(.plain)
                Button("Take another shot") {
                    withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = true; activeTab = .camera }
                }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private func compareImage(_ image: UIImage, label: String, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 27)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: max(1, height - 27))
        }
        .frame(width: width, height: height)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
    }

    private func imageLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: PoserRadius.control))
            .padding(12)
    }

    private func analyze(_ image: UIImage, scene: Bool, imageData: Data? = nil) async {
        let requestID = UUID()
        flowID = requestID
        showLiveCamera = false
        activeTab = .camera
        shootQueue = []
        selectedMatches = []
        referenceImage = image
        isSceneScan = scene
        scannedScene = nil
        sceneMatches = []
        capturedImage = nil
        comparisonNote = nil
        poseScore = nil
        selectedRecipe = nil
        isAnalyzing = true
        do {
            let result = try await AnalysisService.analyze(image, imageData: imageData)
            guard requestID == flowID else { return }
            analysis = result
            selectedRecipe = result.recipe
        } catch {
            guard requestID == flowID else { return }
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private func openPoseGuide() {
        showLiveCamera = true
        activeTab = .camera
        withAnimation(.easeInOut(duration: 0.3)) { showingPoseTutorial = true }
    }

    private func importInspiration(_ image: UIImage, source: InspirationSource, imageData: Data? = nil) async {
        do {
            try inspirationStore.add(image, source: source, originalData: imageData)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await analyze(image, scene: false, imageData: imageData)
    }

    private func scanScene(_ image: UIImage) async {
        let requestID = UUID()
        flowID = requestID
        showLiveCamera = false
        activeTab = .camera
        isSceneScan = false
        scannedScene = image
        sceneMatches = []
        selectedMatches = []
        shootQueue = []
        capturedImage = nil
        selectedRecipe = nil
        referenceImage = nil
        analysis = nil
        isAnalyzing = true

        var candidates = ReferenceCatalog.items.compactMap { reference -> SceneCandidate? in
            guard let image = reference.preview else { return nil }
            return SceneCandidate(id: reference.id, image: image)
        }
        for item in inspirationStore.items {
            if let inspiration = inspirationStore.image(for: item) {
                candidates.append(SceneCandidate(id: item.id, image: inspiration))
            }
        }
        let matches = await SceneMatcher.rank(scene: image, candidates: candidates)
        guard requestID == flowID else { return }
        if matches.isEmpty {
            await analyze(image, scene: true)
        } else {
            sceneMatches = matches
            isAnalyzing = false
        }
    }

    private func matchingImage(for id: UUID) -> UIImage? {
        if let reference = ReferenceCatalog.items.first(where: { $0.id == id }) {
            return reference.image
        }
        guard let item = inspirationStore.items.first(where: { $0.id == id }) else { return nil }
        return inspirationStore.originalData(for: item).flatMap(UIImage.init(data:))
            ?? inspirationStore.image(for: item)
    }

    private func matchingImageData(for id: UUID) -> Data? {
        if let reference = ReferenceCatalog.items.first(where: { $0.id == id }) {
            return reference.imageData
        }
        guard let item = inspirationStore.items.first(where: { $0.id == id }) else { return nil }
        return inspirationStore.originalData(for: item)
    }

    private func matchingTitle(for id: UUID) -> String {
        if let reference = ReferenceCatalog.items.first(where: { $0.id == id }) {
            return reference.title
        }
        return inspirationStore.items.first(where: { $0.id == id })?.title ?? "Saved inspiration"
    }

    private func startSelectedShoot() async {
        guard !selectedMatches.isEmpty, !isPreparingReference else { return }
        isPreparingReference = true
        shootQueue = sceneMatches.map(\.id).filter { selectedMatches.contains($0) }
        guard let firstReference = shootQueue.first else {
            isPreparingReference = false
            return
        }
        currentShotIndex = 0
        await prepareReference(firstReference)
        isPreparingReference = false
    }

    private func prepareReference(_ id: UUID) async {
        let requestID = flowID
        guard let image = matchingImage(for: id) else {
            errorMessage = "This reference is no longer available. Choose another shot."
            shootQueue = []
            return
        }
        do {
            let result = try await AnalysisService.analyze(image, imageData: matchingImageData(for: id))
            guard requestID == flowID else { return }
            referenceImage = image
            analysis = result
            selectedRecipe = result.recipe
            capturedImage = nil
            showLiveCamera = true
            withAnimation(.easeOut(duration: 0.32)) { activeTab = .camera }
            withAnimation(.easeInOut(duration: 0.3)) { showingPoseTutorial = true }
        } catch {
            guard requestID == flowID else { return }
            errorMessage = error.localizedDescription
            shootQueue = []
        }
    }

    private func completeCurrentShot(_ image: UIImage) async {
        guard let referenceImage, !shootQueue.isEmpty, !isSavingShot else { return }
        isSavingShot = true
        defer { isSavingShot = false }
        do {
            try shootStore.add(photo: image, reference: referenceImage)
        } catch {
            errorMessage = "The shot could not be saved to your profile. Try again."
            return
        }
        capturedImage = nil
        comparisonNote = nil
        poseScore = nil
        if currentShotIndex + 1 < shootQueue.count {
            currentShotIndex += 1
            await prepareReference(shootQueue[currentShotIndex])
        } else {
            shootQueue = []
            sceneMatches = []
            selectedMatches = []
            selectedRecipe = nil
            analysis = nil
            self.referenceImage = nil
            showLiveCamera = true
            withAnimation(.easeOut(duration: 0.32)) { activeTab = .profile }
        }
    }

    private func completedShotDetail(_ shot: CompletedShot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Completed shot")
                    .font(.system(size: 28, weight: .bold))
                Text(shot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                if let photo = shootStore.photo(for: shot) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                    Button("Save to Photos") {
                        PhotoLibrarySaver.save(photo) { success in
                            savedMessage = success ? "Your shot is in Photos." : "Allow Photos access in Settings to save this shot."
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                }
                if let reference = shootStore.reference(for: shot) {
                    Text("Reference")
                        .font(.system(size: 17, weight: .semibold))
                    Image(uiImage: reference)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                }
            }
            .padding(PoserSpace.large)
            .foregroundStyle(.white)
        }
        .background(Palette.background.ignoresSafeArea())
    }

    private func compare(_ image: UIImage) async {
        guard let result = try? await AnalysisService.analyze(image) else { return }
        guard capturedImage === image else { return }
        if let reference = analysis,
           let match = PoseMatcher.compare(reference: reference.poseSkeleton, live: result.poseSkeleton,
                                           referenceOutline: reference.shotSpec.silhouette,
                                           liveOutline: result.shotSpec.silhouette) {
            poseScore = match.score
            let focalRatio: CGFloat
            switch reference.shotSpec.focalSource {
            case .exif(let millimeters) where millimeters > 0:
                focalRatio = CGFloat(LensModel.phoneMainEquivalentMM / millimeters)
            default:
                focalRatio = 1
            }
            let mappedOutline = reference.shotSpec.silhouette.map {
                FrameMapping.map($0, fromAspect: reference.shotSpec.imageAspect,
                                 intoAspect: result.shotSpec.imageAspect, focalRatio: focalRatio)
            }
            let overlap = SilhouetteMatcher.frameOverlap(reference: mappedOutline,
                                                         live: result.shotSpec.silhouette)
            comparisonNote = match.score >= 85 && (overlap ?? 100) < 70
                ? "Your pose shape is close. Move or reframe until your outline sits on the guide."
                : match.cue
            return
        }
        guard let referencePoint = analysis?.subjectPoint,
              let capturedPoint = result.subjectPoint else { return }
        let offset = capturedPoint.x - referencePoint.x
        if abs(offset) < 0.08 {
            comparisonNote = "Your subject is close to the reference position. Check the light and background next."
        } else if offset < 0 {
            comparisonNote = "Your subject sits farther left than in the reference. Shift the frame a little right."
        } else {
            comparisonNote = "Your subject sits farther right than in the reference. Shift the frame a little left."
        }
    }

    private func reset() {
        flowID = UUID()
        showLiveCamera = true
        activeTab = .camera
        selectedPhoto = nil
        referenceImage = nil
        analysis = nil
        selectedRecipe = nil
        capturedImage = nil
        isSceneScan = false
        comparisonNote = nil
        poseScore = nil
        scannedScene = nil
        sceneMatches = []
        selectedMatches = []
        shootQueue = []
        currentShotIndex = 0
        isSavingShot = false
        isPreparingReference = false
        showingPoseTutorial = false
        isAnalyzing = false
        showShotDetails = false
    }
}

struct LinkEntryView: View {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Paste a link")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
            Text("Use a public Pinterest or Instagram post, or a direct image URL.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.56))
            TextField("https://…", text: $link)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .padding(15)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: PoserRadius.control))
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button {
                loading = true
                errorMessage = nil
                Task {
                    do { onImage(try await LinkImageLoader.image(from: link)) }
                    catch { errorMessage = error.localizedDescription }
                    loading = false
                }
            } label: {
                Text(loading ? "Loading preview…" : "Use this photo")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
            }
            .buttonStyle(.plain)
            .disabled(loading || link.isEmpty)
            Spacer()
        }
        .padding(24)
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}
