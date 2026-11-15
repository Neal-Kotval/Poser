import SwiftUI
import PhotosUI

private struct ReferenceTagFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    // Pages without this view report .null; never let them erase a real frame.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

private struct SavedInspirationFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    // Pages without this view report .null; never let them erase a real frame.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

enum HomePaging {
    static func allowsSwipe(start: CGPoint, translation: CGSize, excluding frame: CGRect,
                            viewportWidth: CGFloat? = nil) -> Bool {
        guard (frame.isNull || !frame.insetBy(dx: -16, dy: -16).contains(start)),
              abs(translation.width) > abs(translation.height) * 2 else { return false }
        guard let width = viewportWidth else { return true }
        // Only an inward drag from an outside edge can navigate. Interior
        // horizontal scrolling never competes with page navigation.
        if start.x <= 28 { return translation.width > 0 }
        if start.x >= width - 28 { return translation.width < 0 }
        return false
    }

    static func pageStep(translation: CGSize, viewportWidth: CGFloat) -> Int? {
        guard abs(translation.width) >= max(96, viewportWidth * 0.28),
              abs(translation.width) > abs(translation.height) * 2 else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}

private enum PageMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(stiffness: 300, damping: 34)
    }
}

struct HomeView: View {
    private enum Tab: Int, CaseIterable { case home, camera, profile }

    @State private var activeTab: Tab = .camera
    @State private var homePageID = UUID()
    @State private var cameraPageID = UUID()
    @State private var profilePageID = UUID()
    @StateObject private var inspirationStore = InspirationStore()
    @StateObject private var shootStore = ShootStore()
    @StateObject private var profileStore = UserProfileStore()
    @StateObject private var referenceLikes = ReferenceLikeStore()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var importReviewBatch: ImportReviewBatch?
    @State private var confirmedImports: [PendingImport] = []
    @State private var importLoadID = UUID()
    @State private var isLoadingImports = false
    @State private var isSavingImports = false
    @State private var failedImportCount = 0
    @State private var importStartsShoot = true
    @State private var shotAddedToProfile: UIImage?
    @State private var pendingReferenceDeletion: Set<UUID> = []
    @State private var isEditingInspiration = false
    @State private var selectedInspiration: Set<UUID> = []
    @State private var savedInspirationFrame: CGRect = .null
    @State private var referenceImage: UIImage?
    @State private var analysis: PhotoAnalysis?
    @State private var selectedRecipe: ShotRecipe?
    @State private var capturedImage: UIImage?
    @State private var showingPoseTutorial = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var isSceneScan = false
    @State private var comparisonNote: String?
    @State private var poseScore: Int?
    @State private var referencePlan: GeminiReferencePlan?
    @State private var geminiShotFeedback: String?
    @State private var geminiMessage: String?
    @State private var isGeneratingFeedback = false
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
    @State private var selectedReferenceTags: Set<ReferenceTag> = []
    @State private var referenceQuery = ""
    @State private var remoteReferences: [ReferenceAsset]?
    @State private var isRemoteSearching = false
    @State private var referenceSearchTask: Task<Void, Never>?
    @State private var isReferenceSearchExpanded = false
    @State private var isSearchKeyboardVisible = false
    @FocusState private var isReferenceSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var referenceTagFrame: CGRect = .null
    @State private var previewedTab: Tab?
    @State private var isCameraTransitioning = false
    @State private var pageTransitionID = UUID()

    private var isBottomNavigationVisible: Bool {
        !showingPoseTutorial && !isReferenceSearchFocused && !isSearchKeyboardVisible
    }
    @State private var startingSetup = ReferenceStartingSetup()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Extend the pages themselves, not just their background, below
                // the home indicator. Navigation keeps the normal safe area.
                pagePager
                    .ignoresSafeArea(.container, edges: .bottom)
                // Keep the glass surface mounted so its material is ready
                // before it fades back in after keyboard dismissal.
                bottomBar
                    .opacity(isBottomNavigationVisible ? 1 : 0)
                    .offset(y: !reduceMotion && !isBottomNavigationVisible ? 12 : 0)
                    .scaleEffect(!reduceMotion && !isBottomNavigationVisible ? 0.98 : 1, anchor: .bottom)
                    .allowsHitTesting(isBottomNavigationVisible)
                    .accessibilityHidden(!isBottomNavigationVisible)
                    .animation(reduceMotion ? .easeOut(duration: 0.18)
                               : .spring(response: 0.42, dampingFraction: 1),
                               value: isBottomNavigationVisible)
            }
            .background(Palette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if isReferenceSearchFocused { isSearchKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            // Wait until dismissal completes so navigation never rises above
            // a keyboard that is still moving off screen.
            isSearchKeyboardVisible = false
        }
        .overlay {
            if showingPoseTutorial, let selectedRecipe {
                PoseTutorialView(analysis: analysis, recipe: selectedRecipe,
                                 referenceImage: referenceImage, referencePlan: referencePlan,
                                 startingSetup: $startingSetup) {
                    withAnimation(.easeInOut(duration: 0.45)) { showingPoseTutorial = false }
                } onClose: {
                    withAnimation(.easeInOut(duration: 0.45)) { showingPoseTutorial = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onAppear {
            #if DEBUG
            seedDemoProfileIfRequested()
            #endif
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            loadPicked(items, startsShoot: true)
        }
        .sheet(item: $importReviewBatch, onDismiss: {
            let chosen = confirmedImports
            confirmedImports = []
            guard !chosen.isEmpty else { return }
            Task { await addInspiration(chosen) }
        }) { batch in
            ImportReviewView(imports: batch.imports, failedCount: batch.failedCount) { chosen in
                confirmedImports = chosen
                importReviewBatch = nil
            } onCancel: {
                importReviewBatch = nil
            }
        }
        .overlay {
            if isLoadingImports || isSavingImports {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(isLoadingImports ? "Preparing photos…" : "Adding photos…")
                            .font(PoserType.supporting)
                        if isLoadingImports {
                            Button("Cancel") {
                                importLoadID = UUID()
                                isLoadingImports = false
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(24)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
                }
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
        .confirmationDialog(pendingReferenceDeletion.count == 1 ? "Delete this reference photo?"
                            : "Delete \(pendingReferenceDeletion.count) reference photos?", isPresented: Binding(
            get: { !pendingReferenceDeletion.isEmpty },
            set: { if !$0 { pendingReferenceDeletion = [] } }
        ), titleVisibility: .visible, presenting: pendingReferenceDeletion) { ids in
            Button(ids.count == 1 ? "Delete reference" : "Delete \(ids.count) references",
                   role: .destructive) {
                deleteReferences(ids)
            }
            Button("Cancel", role: .cancel) { pendingReferenceDeletion = [] }
        } message: { _ in
            Text("This removes saved photos from Poser. Your photo library is unchanged.")
        }
    }

    private var pagePager: some View {
        SmoothPagePager(selection: activeTab.rawValue, pageCount: Tab.allCases.count,
                        canBegin: { start, translation, width in
            guard !isReferenceSearchFocused && !isSearchKeyboardVisible else { return false }
            guard activeTab != .home || savedInspirationFrame.isNull
                || !savedInspirationFrame.insetBy(dx: -16, dy: -16).contains(start) else { return false }
            return HomePaging.allowsSwipe(start: start, translation: translation,
                                         excluding: activeTab == .home ? referenceTagFrame : .null,
                                         viewportWidth: width)
        }, onPreview: { index in
            if let index, let tab = Tab(rawValue: index) {
                preparePage(tab)
                previewedTab = tab
            } else {
                previewedTab = nil
            }
        }, onNavigate: { index in
            if let tab = Tab(rawValue: index) { navigate(to: tab, prepare: false) }
        }) {
            HStack(spacing: 0) {
                homePage.id(homePageID).containerRelativeFrame(.horizontal)
                cameraPage.id(cameraPageID).containerRelativeFrame(.horizontal)
                profilePage.id(profilePageID).containerRelativeFrame(.horizontal)
            }
        }
        .coordinateSpace(name: "homePager")
        .onPreferenceChange(ReferenceTagFrameKey.self) { referenceTagFrame = $0 }
        .onPreferenceChange(SavedInspirationFrameKey.self) { savedInspirationFrame = $0 }
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
            shotSpec: analysis.map { $0.shotSpec.withSubjectBox($0.subjectBox) },
            referenceImage: selectedRecipe == nil ? nil : referenceImage,
            referenceTitle: shootQueue.isEmpty ? nil : matchingTitle(for: shootQueue[currentShotIndex]),
            queueProgress: shootQueue.isEmpty ? nil : (currentShotIndex + 1, shootQueue.count),
            embedded: true,
            isActive: activeTab == .camera || previewedTab == .camera || isCameraTransitioning,
            isGuideOverlayVisible: showingPoseTutorial
        ) { image in
            if !shootQueue.isEmpty {
                capturedImage = image
                comparisonNote = nil
                poseScore = nil
                geminiShotFeedback = nil
                geminiMessage = nil
                withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = false }
                Task { await compare(image) }
            } else if selectedRecipe != nil, referenceImage != nil {
                capturedImage = image
                comparisonNote = nil
                poseScore = nil
                geminiShotFeedback = nil
                geminiMessage = nil
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
        ScrollViewReader { scroll in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    landing
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, PoserSpace.large)
                .padding(.top, PoserSpace.medium)
                .padding(.bottom, 86)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isReferenceSearchExpanded) { _, expanded in
                if expanded { centerReferenceSearch(using: scroll) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // Center again in the final keyboard-adjusted viewport, rather
                // than leaving suggestions below the keyboard after expansion.
                if isReferenceSearchFocused { centerReferenceSearch(using: scroll) }
            }
        }
        .background(Palette.background)
    }

    private func centerReferenceSearch(using scroll: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            scroll.scrollTo("reference-search-bubble", anchor: .center)
        }
    }

    private var shootPage: some View {
        ScrollView(showsIndicators: false) {
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
            .padding(.bottom, 148)
            .frame(maxWidth: .infinity)
        }
        .id(capturedImage == nil ? "shot-plan" : "shot-review")
        .background(Palette.background)
    }

    #if DEBUG
    /// Launch with `-PoserDemoProfile` to fill an empty profile with sample shots and open it;
    /// add `-PoserOpenFirstShot` to also open the newest post.
    private func seedDemoProfileIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PoserDemoProfile") else { return }
        activeTab = .profile
        if !shootStore.shots.isEmpty {
            if ProcessInfo.processInfo.arguments.contains("-PoserOpenFirstShot") {
                selectedCompletedShot = shootStore.shots.first
            }
            return
        }
        let references = ReferenceCatalog.items.prefix(16).compactMap { item in item.image.map { (item.id, $0) } }
        guard references.count >= 9 else { return }
        let scores = [61, 68, 64, 73, 79, 76, 84, 88, 91]
        for (index, score) in scores.enumerated() {
            let (id, image) = references[index]
            let photo = references[index + 1].1
            let day = Calendar.current.date(byAdding: .day, value: -(scores.count - 1 - index) / 2, to: Date())!
            try? shootStore.add(photo: photo, reference: image, matchScore: score, referenceID: id,
                                createdAt: day.addingTimeInterval(Double(index) * 60))
        }
        for (_, image) in references.suffix(5) {
            try? inspirationStore.add(image, source: .photoLibrary)
        }
        profileStore.updateDisplayName("Nathan")
        profileStore.updateBio("Golden hour enjoyer. Recreating Pinterest shots one pose at a time.")
        if let first = shootStore.shots.first, first.commentList.isEmpty {
            try? shootStore.toggleLike(first.id)
            try? shootStore.addComment("Finally got the lean right 🙌", author: "Nathan", to: first.id)
        }
        if ProcessInfo.processInfo.arguments.contains("-PoserOpenFirstShot") {
            selectedCompletedShot = shootStore.shots.first
        }
    }
    #endif

    private var profilePage: some View {
        ProfileView(
            profileStore: profileStore,
            shootStore: shootStore,
            inspirationStore: inspirationStore,
            onOpenReference: { openSavedReference($0) },
            onAddPoses: { loadPicked($0, startsShoot: false) },
            onDeleteReference: { pendingReferenceDeletion = [$0] },
            onOpenCamera: {
                withAnimation(.easeOut(duration: 0.32)) { activeTab = .camera }
            },
            onSelectShot: { selectedCompletedShot = $0 }
        )
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
                .padding(.bottom, 8)
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
            navigate(to: tab)
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

    private func navigate(to tab: Tab, prepare: Bool = true) {
        guard activeTab != tab else { return }
        let transitionID = UUID()
        pageTransitionID = transitionID
        if activeTab == .camera { isCameraTransitioning = true }
        if prepare { preparePage(tab) }
        if activeTab == .camera { flowID = UUID() }
        withAnimation(PageMotion.animation(reduceMotion: reduceMotion), completionCriteria: .logicallyComplete) {
            activeTab = tab
            previewedTab = nil
        } completion: {
            // Keep the outgoing live preview running until it is off screen.
            if transitionID == pageTransitionID { isCameraTransitioning = false }
        }
        errorMessage = nil
        savedMessage = nil
    }

    private func preparePage(_ tab: Tab) {
        // Reset before the incoming page is dragged into view, rather than
        // replacing its hierarchy when the finger lifts.
        if tab == .camera {
            reset(returnToCamera: false)
            cameraPageID = UUID()
        }
        if tab == .home {
            closeReferenceSearch()
            selectedReferenceTags = []
            referenceQuery = ""
            referenceSearchTask?.cancel()
            remoteReferences = nil
            isRemoteSearching = false
            isEditingInspiration = false
            selectedInspiration = []
            pendingReferenceDeletion = []
            selectedPhotos = []
            importLoadID = UUID()
            isLoadingImports = false
            importReviewBatch = nil
            confirmedImports = []
            homePageID = UUID()
        }
        if tab == .profile {
            selectedCompletedShot = nil
            profilePageID = UUID()
        }
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
        VStack(alignment: .leading, spacing: 16) {
            savedInspiration

            if GeminiImageCoach.isConfigured {
                Text("Reference photos are sent to Gemini for shot suggestions.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }

            HStack {
                Text("For you")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if isRemoteSearching {
                    ProgressView().tint(.white).scaleEffect(0.8)
                }
                Text("\(filteredReferences.count) photos")
                    .font(PoserType.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            referenceSearchBubble
                .padding(.top, -4)
                .id("reference-search-bubble")

            if filteredReferences.isEmpty {
                ContentUnavailableView {
                    Label("No references found", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another search or category.")
                } actions: {
                    Button("Clear search and filters") {
                        referenceQuery = ""
                        selectedReferenceTags = []
                        remoteReferences = nil
                    }
                }
            }

            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(filteredReferences) { asset in
                    if let image = asset.preview {
                        feedCard(asset, image: image)
                    }
                }
            }
        }
        .onChange(of: referenceQuery) { _, _ in scheduleReferenceSearch() }
        .onChange(of: selectedReferenceTags) { _, _ in scheduleReferenceSearch() }
    }

    private var filteredReferences: [ReferenceAsset] {
        if let remoteReferences { return remoteReferences }
        return ReferenceCatalog.feed(matching: selectedReferenceTags, query: referenceQuery)
    }

    private func scheduleReferenceSearch() {
        referenceSearchTask?.cancel()
        remoteReferences = nil
        isRemoteSearching = false
        let query = referenceQuery
        let tags = selectedReferenceTags
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              tags.count <= 1 else { return }
        isRemoteSearching = TypesenseConfig.isConfigured
        referenceSearchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            let results = await ReferenceSearch.text(query, tag: tags.first)
            guard !Task.isCancelled else { return }
            remoteReferences = results
            isRemoteSearching = false
        }
    }

    private var referenceSearchBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 24, height: 52)
                    .contentShape(Rectangle())
                    .onTapGesture { isReferenceSearchFocused = true }
                TextField("Search references", text: $referenceQuery)
                    .font(PoserType.body)
                    .frame(minHeight: 52)
                    .focused($isReferenceSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("referenceSearchField")
                    .onSubmit { closeReferenceSearch() }
                if !referenceQuery.isEmpty {
                    Button {
                        referenceQuery = ""
                        remoteReferences = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.secondaryText)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear search")
                }
                if isReferenceSearchExpanded {
                    Button(action: closeReferenceSearch) {
                        Image(systemName: "chevron.up")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Collapse search")
                }
            }
            .frame(minHeight: 52)

            if isReferenceSearchExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().overlay(Palette.border)
                    Text("Explore categories")
                        .font(PoserType.caption)
                        .foregroundStyle(Palette.secondaryText)
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                            referenceTagButton(nil)
                            ForEach(ReferenceCatalog.tags) { tag in
                                referenceTagButton(tag)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(height: 188)
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("referenceCategorySuggestions")
                }
                .padding(.bottom, 16)
                .transition(.opacity)
            } else if !selectedReferenceTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ReferenceCatalog.tags.filter { selectedReferenceTags.contains($0) }) { tag in
                            Button { selectedReferenceTags.remove(tag) } label: {
                                Label(tag.title, systemImage: "xmark.circle.fill")
                                    .font(PoserType.caption)
                                    .foregroundStyle(Palette.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 44)
                                    .background(.white.opacity(0.06), in: Capsule())
                            }
                            .accessibilityLabel("Remove \(tag.title) filter")
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .foregroundStyle(Palette.primaryText)
        .poserGlass(cornerRadius: isReferenceSearchExpanded ? 28 : 26)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                   value: isReferenceSearchExpanded)
        .onChange(of: isReferenceSearchFocused) { _, focused in
            if focused { isReferenceSearchExpanded = true }
        }
        .onChange(of: activeTab) { _, tab in
            if tab != .home { closeReferenceSearch() }
        }
        .accessibilityIdentifier("referenceSearchBubble")
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReferenceTagFrameKey.self,
                                       value: geometry.frame(in: .named("homePager")))
            }
        }
    }

    private func closeReferenceSearch() {
        isReferenceSearchFocused = false
        isReferenceSearchExpanded = false
    }

    private func referenceTagButton(_ tag: ReferenceTag?) -> some View {
        let isSelected = tag.map { selectedReferenceTags.contains($0) } ?? selectedReferenceTags.isEmpty
        return Button {
            if let tag {
                if selectedReferenceTags.contains(tag) { selectedReferenceTags.remove(tag) }
                else { selectedReferenceTags.insert(tag) }
            } else {
                selectedReferenceTags = []
            }
            isReferenceSearchFocused = false
        } label: {
            Text(tag?.title ?? "All")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isSelected ? Palette.background : Palette.primaryText)
                .background(isSelected ? .white : .white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(tag.map { "\(isSelected ? "Remove" : "Add") \($0.title) filter" } ?? "Clear all category filters")
    }

    private func feedCard(_ asset: ReferenceAsset, image: UIImage) -> some View {
        let post = asset.mockPost
        let tags = [
            asset.setting.map { ReferenceTag(kind: .setting, value: $0) },
            asset.pose.map { ReferenceTag(kind: .pose, value: $0) }
        ].compactMap { $0 }
        let shape = RoundedRectangle(cornerRadius: PoserRadius.image, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            Button {
                if let data = asset.imageData, let fullImage = UIImage(data: data) {
                    Task { await analyze(fullImage, scene: false, imageData: data) }
                }
            } label: {
                GeometryReader { tile in
                    ReferenceFeedPhoto(asset: asset, placeholder: image)
                        .frame(width: tile.size.width, height: tile.size.height)
                        .clipped()
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Text(post.initials)
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(.white.opacity(0.14), in: Circle())
                        Text(post.accountName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 3)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Text(tag.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .clipShape(shape)
                // Bound the photo's tap area to its visible rounded card.
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(asset.title) inspiration. Demo account \(post.accountName).")

            ReferenceLikeButton(isLiked: referenceLikes.isLiked(asset.assetName),
                                count: post.likeCount + (referenceLikes.isLiked(asset.assetName) ? 1 : 0)) {
                referenceLikes.toggle(asset.assetName)
            }
            .padding(12)
        }
    }

    private var savedInspiration: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: -12) {
                HStack {
                    Text("Your inspiration")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    if !isEditingInspiration {
                        PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10,
                                     selectionBehavior: .ordered, matching: .images) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .poserGlass(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add reference photos")
                    }
                }
                .frame(minHeight: 44)
                if !inspirationStore.items.isEmpty {
                    HStack(spacing: 8) {
                        Text(isEditingInspiration ? "\(selectedInspiration.count) selected"
                             : "\(inspirationStore.items.count) saved")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                        Button(isEditingInspiration ? "Done" : "Edit") {
                            isEditingInspiration.toggle()
                            selectedInspiration = []
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(isEditingInspiration ? "Finish editing inspiration" : "Edit saved inspiration")
                        Spacer(minLength: 0)
                        if isEditingInspiration {
                            Button(selectedInspiration.count == inspirationStore.items.count ? "Deselect all" : "Select all") {
                                selectedInspiration = selectedInspiration.count == inspirationStore.items.count
                                    ? [] : Set(inspirationStore.items.map(\.id))
                            }
                            .frame(minHeight: 44)
                            Button("Delete (\(selectedInspiration.count))", role: .destructive) {
                                pendingReferenceDeletion = selectedInspiration
                            }
                            .frame(minHeight: 44)
                            .disabled(selectedInspiration.isEmpty)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            if inspirationStore.items.isEmpty {
                Text("Add photos to save inspiration for your next shoot.")
                    .font(PoserType.supporting)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(inspirationStore.items) { item in
                            if let image = inspirationStore.image(for: item) {
                                savedInspirationCard(item, image: image)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SavedInspirationFrameKey.self,
                                               value: geometry.frame(in: .named("homePager")))
                    }
                }
            }
        }
    }

    private func savedInspirationCard(_ item: InspirationItem, image: UIImage) -> some View {
        let selected = selectedInspiration.contains(item.id)
        return Button {
            if isEditingInspiration {
                if selected { selectedInspiration.remove(item.id) }
                else { selectedInspiration.insert(item.id) }
            } else {
                Task {
                    let original = inspirationStore.originalData(for: item)
                    await analyze(original.flatMap(UIImage.init(data:)) ?? image,
                                  scene: false, imageData: original)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 132, height: 132)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                    .contentShape(Rectangle())
                    .overlay {
                        if isEditingInspiration && selected {
                            RoundedRectangle(cornerRadius: PoserRadius.image)
                                .stroke(.white, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isEditingInspiration {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.6), in: Circle())
                                .padding(8)
                        }
                    }
            }
            .frame(width: 132, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEditingInspiration ? "Select saved reference" : "Open saved reference")
        .accessibilityAddTraits(selected && isEditingInspiration ? [.isSelected] : [])
        .contextMenu {
            if !isEditingInspiration {
                Button("Delete reference", systemImage: "trash", role: .destructive) {
                    pendingReferenceDeletion = [item.id]
                }
            }
        }
    }

    private func deleteReferences(_ ids: Set<UUID>) {
        pendingReferenceDeletion = []
        let previousIDs = Set(inspirationStore.items.map(\.id))
        do {
            try inspirationStore.remove(ids: ids)
        } catch {
            errorMessage = "Could not delete reference photos. \(error.localizedDescription)"
        }
        let removed = previousIDs.subtracting(inspirationStore.items.map(\.id))
        if !removed.isDisjoint(with: shootQueue) {
            let tab = activeTab
            reset()
            activeTab = tab
        }
        selectedMatches.subtract(removed)
        sceneMatches.removeAll { removed.contains($0.id) }
        selectedInspiration.subtract(removed)
        if inspirationStore.items.isEmpty { isEditingInspiration = false }
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
                Image(uiImage: referenceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(Palette.surface)
                    .overlay(alignment: .topLeading) {
                        imageLabel(isSceneScan ? "YOUR SCENE" : "REFERENCE")
                    }
            }
            if let analysis {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SHOT PLAN")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Palette.secondaryText)
                    Text(referencePlan?.summary ?? analysis.summary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text(referencePlan == nil
                         ? "Based on on-device analysis; refine in the pose guide."
                         : "Suggested from the photo; refine in the pose guide.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                instruction(symbol: "arrow.left.and.right", title: "Distance", body: analysis.map {
                    $0.shotSpec.distanceMeters != nil ? $0.geometry.distanceLabel :
                    "Start \(ShotSpec.formatDistance(startingSetup.distanceMeters)) away" +
                    ($0.faceDistanceMeters != nil ? " (face estimate)" : " (adjustable)")
                } ?? recipe.camera)
                rowDivider
                instruction(symbol: "iphone", title: "Phone height", body: analysis.map {
                    $0.shotSpec.cameraHeightRatio != nil ? $0.geometry.adjustmentLabel :
                    "Start ≈\(startingSetup.heightMeters.formatted(.number.precision(.fractionLength(1)))) m high (adjustable)"
                } ?? "Analyzing reference")
                rowDivider
                instruction(symbol: "angle", title: "Camera tilt", body: analysis.map {
                    $0.shotSpec.pitchDegrees != nil ? $0.geometry.angleLabel :
                    "Start at \(Int(startingSetup.tiltDegrees))° (adjustable)"
                } ?? "Analyzing reference")
                rowDivider
                instruction(symbol: "figure.stand", title: "Pose", body: analysis?.poseSkeleton?.shortCue
                            ?? referencePlan.flatMap { $0.hasPerson && !$0.poseCue.isEmpty ? $0.poseCue : nil }
                            ?? "Pose not measured; use the photo as your guide.")
            }
            if let analysis, analysis.shotSpec.source != .pose3D {
                Text("These starting values are adjustable in the pose guide. Height and tilt are not measured from this photo.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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
                    instruction(symbol: "sun.max", title: "Light", body: referencePlan.flatMap { $0.lightCue.isEmpty ? nil : $0.lightCue }
                                ?? (analysis == nil ? recipe.light : "Match the light direction in the reference."))
                    rowDivider
                    instruction(symbol: "square.dashed", title: "Frame", body: referencePlan.flatMap { $0.framingCue.isEmpty ? nil : $0.framingCue }
                                ?? (analysis == nil ? recipe.framing : "Place the subject where they appear in the reference."))
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
            if GeminiImageCoach.isConfigured, let referenceImage {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await generateFeedback(reference: referenceImage, shot: image) }
                    } label: {
                        Label(isGeneratingFeedback ? "Comparing photos…" : "Get photo tips",
                              systemImage: "sparkles")
                    }
                    .disabled(isGeneratingFeedback)
                    Text("Sends both photos to Gemini when you tap.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                    if isGeneratingFeedback { ProgressView().tint(.white) }
                    if let geminiShotFeedback { Text(geminiShotFeedback).font(.system(size: 14)) }
                    if let geminiMessage { Text(geminiMessage).font(.system(size: 13)).foregroundStyle(Palette.secondaryText) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
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
                    geminiShotFeedback = nil
                    geminiMessage = nil
                    withAnimation(.easeOut(duration: 0.32)) { showLiveCamera = true; activeTab = .camera }
                }
                .disabled(isSavingShot)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                if let referenceImage {
                    let added = shotAddedToProfile === image
                    Button {
                        do {
                            try shootStore.add(photo: image, reference: referenceImage, matchScore: poseScore)
                            shotAddedToProfile = image
                        } catch {
                            errorMessage = "The shot could not be added to your profile. Try again."
                        }
                    } label: {
                        Label(added ? "Added to profile" : "Add to profile",
                              systemImage: added ? "checkmark" : "person.crop.square")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                            .opacity(added ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                }
                Button {
                    PhotoLibrarySaver.save(image) { success in
                        savedMessage = success ? "Your shot is in Photos." : "Allow Photos access in Settings to save this shot."
                    }
                } label: {
                    Text("Save to Photos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(referenceImage == nil ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(referenceImage == nil ? Color.white : Palette.elevated,
                                    in: RoundedRectangle(cornerRadius: PoserRadius.control))
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
        referencePlan = nil
        geminiShotFeedback = nil
        geminiMessage = nil
        selectedRecipe = nil
        isAnalyzing = true
        do {
            let result = try await AnalysisService.analyze(image, imageData: imageData)
            guard requestID == flowID else { return }
            let plan = await preprocessReference(image, analysis: result)
            guard requestID == flowID else { return }
            analysis = result
            startingSetup = ReferenceStartingSetup(spec: result.shotSpec,
                                                   faceDistanceMeters: result.faceDistanceMeters)
            if let plan { startingSetup.apply(plan, preserving: result.shotSpec) }
            referencePlan = plan
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

    private func loadPicked(_ items: [PhotosPickerItem], startsShoot: Bool) {
        guard !items.isEmpty else { return }
        importStartsShoot = startsShoot
        let requestID = UUID()
        importLoadID = requestID
        isLoadingImports = true
        Task {
            var loaded: [PendingImport] = []
            for item in items.prefix(10) {
                guard requestID == importLoadID else { return }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    loaded.append(PendingImport(image: image, data: data))
                }
            }
            guard requestID == importLoadID else { return }
            isLoadingImports = false
            failedImportCount = min(items.count, 10) - loaded.count
            if loaded.isEmpty {
                errorMessage = "These photos could not be loaded. Try selecting them again."
            } else {
                importReviewBatch = ImportReviewBatch(imports: loaded, failedCount: failedImportCount)
            }
        }
    }

    private func openSavedReference(_ item: InspirationItem) {
        guard let preview = inspirationStore.image(for: item) else { return }
        Task {
            let original = inspirationStore.originalData(for: item)
            await analyze(original.flatMap(UIImage.init(data:)) ?? preview, scene: false, imageData: original)
        }
    }

    /// Only called after the review sheet has confirmed and dismissed.
    private func addInspiration(_ chosen: [PendingImport]) async {
        guard !chosen.isEmpty, !isSavingImports else { return }
        if importStartsShoot, chosen.count == 1, let only = chosen.first {
            await importInspiration(only.image, source: .photoLibrary, imageData: only.data)
            return
        }
        isSavingImports = true
        defer { isSavingImports = false }
        var savedCount = 0
        for item in chosen.reversed() {
            do {
                try inspirationStore.add(item.image, source: .photoLibrary, originalData: item.data)
                savedCount += 1
                await Task.yield()
            } catch {
                errorMessage = "Saved \(savedCount) of \(chosen.count) photos. \(error.localizedDescription)"
                return
            }
        }
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

        var inspirationCandidates: [SceneCandidate] = []
        for item in inspirationStore.items {
            if let inspiration = inspirationStore.image(for: item) {
                inspirationCandidates.append(SceneCandidate(id: item.id, image: inspiration))
            }
        }
        let matches = await ReferenceSearch.sceneMatches(for: image, inspiration: inspirationCandidates)
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
            let plan = await preprocessReference(image, analysis: result)
            guard requestID == flowID else { return }
            referenceImage = image
            analysis = result
            referencePlan = plan
            geminiShotFeedback = nil
            geminiMessage = nil
            startingSetup = ReferenceStartingSetup(spec: result.shotSpec,
                                                   faceDistanceMeters: result.faceDistanceMeters)
            if let plan { startingSetup.apply(plan, preserving: result.shotSpec) }
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
            try shootStore.add(photo: image, reference: referenceImage, matchScore: poseScore,
                               referenceID: shootQueue[currentShotIndex])
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
        ShotPostView(shot: shot, shootStore: shootStore, profileStore: profileStore) {
            selectedCompletedShot = nil
        }
    }

    private func compare(_ image: UIImage) async {
        guard let result = try? await AnalysisService.analyze(image) else { return }
        guard capturedImage === image else { return }
        guard let reference = analysis, reference.poseSkeleton != nil else {
            comparisonNote = "No measurable person pose was found in the reference photo. Choose a clearer reference to get a pose score."
            return
        }
        guard result.poseSkeleton != nil else {
            comparisonNote = "No measurable person pose was found in your photo. Keep your arms and legs in view, then try again."
            return
        }
        if let match = PoseMatcher.compare(reference: reference.poseSkeleton, live: result.poseSkeleton,
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
            let mappedOutline = FrameMapping.mapOutline(reference.shotSpec.silhouette,
                                                        fromAspect: reference.shotSpec.imageAspect,
                                                        intoAspect: result.shotSpec.imageAspect,
                                                        focalRatio: focalRatio)
            let overlap = SilhouetteMatcher.frameOverlap(reference: mappedOutline,
                                                         live: result.shotSpec.silhouette)
            comparisonNote = match.score >= 85 && (overlap ?? 100) < 70
                ? "Your pose shape is close. Move or reframe to match the reference."
                : match.cue
            return
        }
        comparisonNote = "Not enough matching arm and leg joints were visible to score this pose. Try a clearer full-body shot."
    }

    private func preprocessReference(_ image: UIImage, analysis: PhotoAnalysis) async -> GeminiReferencePlan? {
        guard GeminiImageCoach.isConfigured else { return nil }
        return try? await GeminiImageCoach.planReference(image, visionHasPerson: analysis.hasPerson,
                                                        hasMeasuredPose: analysis.poseSkeleton != nil)
    }

    private func generateFeedback(reference: UIImage, shot: UIImage) async {
        guard !isGeneratingFeedback else { return }
        isGeneratingFeedback = true
        geminiMessage = nil
        defer { isGeneratingFeedback = false }
        do {
            let note = try await GeminiImageCoach.compare(reference: reference, shot: shot,
                                                           measuredScore: poseScore, measuredCue: comparisonNote)
            guard referenceImage === reference, capturedImage === shot else { return }
            geminiShotFeedback = note
        } catch {
            guard capturedImage === shot else { return }
            geminiMessage = error.localizedDescription
        }
    }

    private func reset(returnToCamera: Bool = true) {
        flowID = UUID()
        showLiveCamera = true
        if returnToCamera { activeTab = .camera }
        selectedPhotos = []
        importLoadID = UUID()
        isLoadingImports = false
        importReviewBatch = nil
        confirmedImports = []
        referenceImage = nil
        analysis = nil
        selectedRecipe = nil
        capturedImage = nil
        isSceneScan = false
        comparisonNote = nil
        poseScore = nil
        referencePlan = nil
        geminiShotFeedback = nil
        geminiMessage = nil
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
        startingSetup = ReferenceStartingSetup()
    }
}

private struct ReferenceLikeButton: View {
    let isLiked: Bool
    let count: Int
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? Color.pink : .white.opacity(0.9))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isLiked)
                    .symbolEffectsRemoved(reduceMotion)
                Text(count.formatted())
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .frame(minWidth: 44, minHeight: 44, alignment: .bottomTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: isLiked)
        .accessibilityLabel(isLiked ? "Unlike reference" : "Like reference")
        .accessibilityValue("\(count) likes, including mock engagement")
        .accessibilityAddTraits(isLiked ? [.isSelected] : [])
    }
}

private struct ReferenceFeedPhoto: View {
    let asset: ReferenceAsset
    let placeholder: UIImage
    @State private var fullImage: UIImage?

    var body: some View {
        Image(uiImage: fullImage ?? placeholder)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .task(id: asset.id) {
                let reference = asset
                let loaded = await Task.detached(priority: .userInitiated) {
                    reference.feedImage
                }.value
                guard !Task.isCancelled else { return }
                fullImage = loaded
            }
            .onDisappear { fullImage = nil }
    }
}

/// Owns gesture state so a drag only updates the page transform.
private struct SmoothPagePager<Content: View>: View {
    let selection: Int
    let pageCount: Int
    let canBegin: (CGPoint, CGSize, CGFloat) -> Bool
    let onPreview: (Int?) -> Void
    let onNavigate: (Int) -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var gestureActive = false
    @State private var dragOffset: CGFloat = 0
    @State private var evaluatedDrag = false
    @State private var dragTarget: Int?
    @State private var dragGeneration = UUID()

    private var settlingAnimation: Animation? {
        PageMotion.animation(reduceMotion: reduceMotion)
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .offset(x: -CGFloat(selection) * geometry.size.width + dragOffset)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .animation(settlingAnimation, value: selection)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("homePager"))
                        .updating($gestureActive) { _, active, _ in active = true }
                        .onChanged { value in
                            if !evaluatedDrag {
                                dragGeneration = UUID()
                                evaluatedDrag = true
                                let target = selection + (value.translation.width < 0 ? 1 : -1)
                                if (0..<pageCount).contains(target),
                                   canBegin(value.startLocation, value.translation, geometry.size.width) {
                                    dragTarget = target
                                    onPreview(target)
                                }
                            }
                            guard let target = dragTarget else { return }
                            let amount = target > selection
                                ? min(0, max(-geometry.size.width, value.translation.width))
                                : max(0, min(geometry.size.width, value.translation.width))
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { dragOffset = amount }
                        }
                        .onEnded { value in
                            let generation = dragGeneration
                            let target = dragTarget
                            let step = HomePaging.pageStep(translation: value.translation,
                                                           viewportWidth: geometry.size.width)
                            withAnimation(settlingAnimation, completionCriteria: .logicallyComplete) {
                                // Both terms of the transform change in the same
                                // transaction: no independent gesture-state snap.
                                dragOffset = 0
                                if let target, let step, target == selection + step {
                                    onNavigate(target)
                                }
                            } completion: {
                                if generation == dragGeneration { onPreview(nil) }
                            }
                            finishGesture()
                        }
                )
                .onChange(of: gestureActive) { _, active in
                    if !active && evaluatedDrag {
                        let generation = dragGeneration
                        withAnimation(settlingAnimation, completionCriteria: .logicallyComplete) {
                            dragOffset = 0
                        } completion: {
                            if generation == dragGeneration { onPreview(nil) }
                        }
                        finishGesture()
                    }
                }
                .onChange(of: selection) { _, _ in
                    // Programmatic navigation may interrupt a held gesture.
                    if dragOffset != 0 {
                        withAnimation(settlingAnimation) { dragOffset = 0 }
                    }
                }
        }
    }

    private func finishGesture() {
        evaluatedDrag = false
        dragTarget = nil
    }
}

private struct ImportReviewBatch: Identifiable {
    let id = UUID()
    let imports: [PendingImport]
    let failedCount: Int
}

struct PendingImport: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data?
}

/// Shows picked photos before they are saved, so a mistaken tap in the picker
/// can be undone by deselecting instead of silently starting a shoot.
struct ImportReviewView: View {
    let imports: [PendingImport]
    var failedCount: Int = 0
    let onConfirm: ([PendingImport]) -> Void
    let onCancel: () -> Void
    @State private var excluded: Set<UUID> = []

    private var chosen: [PendingImport] { imports.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(imports.count == 1 ? "Use this photo?" : "Review photos")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.system(size: 15, weight: .medium))
                    .frame(minHeight: 44)
            }
            Text("Tap a photo to remove it or tap again to keep it. Nothing is saved until you confirm.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondaryText)
            if failedCount > 0 {
                Text("\(failedCount) \(failedCount == 1 ? "photo couldn’t" : "photos couldn’t") be loaded. Cancel to try again.")
                    .font(PoserType.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: imports.count == 1 ? 1 : 3), spacing: 8) {
                    ForEach(imports) { item in
                        let isChosen = !excluded.contains(item.id)
                        Button {
                            if isChosen { excluded.insert(item.id) } else { excluded.remove(item.id) }
                        } label: {
                            GeometryReader { tile in
                                Image(uiImage: item.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: tile.size.width, height: tile.size.height)
                                    .clipped()
                            }
                            .aspectRatio(imports.count == 1 ? 0.8 : 1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                            .contentShape(Rectangle())
                            .opacity(isChosen ? 1 : 0.35)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .medium))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(isChosen ? .black : .white, .white)
                                    .shadow(radius: 3)
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo \((imports.firstIndex { $0.id == item.id } ?? 0) + 1), \(isChosen ? "selected" : "removed")")
                        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
                        .accessibilityHint("Double tap to \(isChosen ? "remove" : "keep") this photo")
                    }
                }
            }
            Button { onConfirm(chosen) } label: {
                Text("Add \(chosen.count) \(chosen.count == 1 ? "photo" : "photos")")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
            }
            .buttonStyle(.plain)
            .disabled(chosen.isEmpty)
            .opacity(chosen.isEmpty ? 0.4 : 1)
        }
        .padding(24)
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}
