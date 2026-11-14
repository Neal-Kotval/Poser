import SwiftUI
import PhotosUI

struct HomeView: View {
    private enum Tab: Hashable { case camera, home, profile }

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

    var body: some View {
        NavigationStack {
            TabView(selection: $activeTab) {
                cameraPage
                    .tag(Tab.camera)
                homePage
                    .tag(Tab.home)
                profilePage
                    .tag(Tab.profile)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Palette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    await importInspiration(image, source: .photoLibrary)
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

    private var cameraPage: some View {
        CameraScreen(
            mode: .guide,
            recipe: selectedRecipe,
            targetX: analysis?.subjectPoint?.x ?? 0.5,
            targetPose: analysis?.poseSkeleton,
            shotGeometry: analysis?.geometry,
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
                withAnimation(.easeOut(duration: 0.32)) { activeTab = .home }
                Task { await compare(image) }
            } else if selectedRecipe != nil, referenceImage != nil {
                capturedImage = image
                comparisonNote = nil
                poseScore = nil
                withAnimation(.easeOut(duration: 0.32)) { activeTab = .home }
                Task { await compare(image) }
            } else {
                Task { await scanScene(image) }
            }
        } onPoseGuide: {
            openPoseGuide()
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let capturedImage {
                    comparison(capturedImage)
                } else if !sceneMatches.isEmpty && shootQueue.isEmpty {
                    sceneMatchResults
                } else if let selectedRecipe {
                    recipeDetail(selectedRecipe)
                } else if isAnalyzing || isPreparingReference {
                    analyzingView
                } else {
                    landing
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, PoserSpace.large)
            .padding(.top, PoserSpace.large)
            .padding(.bottom, PoserSpace.xLarge)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
    }

    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("poser")
                        .font(PoserType.wordmark)
                    Spacer()
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24, weight: .ultraLight))
                }
                .padding(.top, PoserSpace.large)

                HStack(spacing: 18) {
                    Circle()
                        .fill(Palette.elevated)
                        .frame(width: 74, height: 74)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 29)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("My shots")
                            .font(.system(size: 24, weight: .bold))
                        Text("\(shootStore.shots.count) completed")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }

                Rectangle().fill(Palette.border).frame(height: 1)
                if shootStore.shots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 28, weight: .ultraLight))
                        Text("Your shoots will live here")
                            .font(.system(size: 19, weight: .semibold))
                        Text("Scan a place, choose inspiration, and finish your first shot.")
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
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
            .padding(.bottom, PoserSpace.xLarge)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if activeTab == .home, !sceneMatches.isEmpty, shootQueue.isEmpty, capturedImage == nil {
                Button { Task { await startSelectedShoot() } } label: {
                    Text(isPreparingReference ? "Preparing your shots…" : "Continue with \(selectedMatches.count) \(selectedMatches.count == 1 ? "shot" : "shots")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedMatches.isEmpty || isPreparingReference)
                .opacity(selectedMatches.isEmpty ? 0.4 : 1)
                .padding(.horizontal, PoserSpace.large)
                .padding(.top, 10)
            }
            HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.32)) { activeTab = .home } } label: {
                VStack(spacing: 4) {
                    Image(systemName: activeTab == .home ? "house.fill" : "house")
                        .font(.system(size: 20))
                    Text("Home")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(activeTab == .home ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")
            Button {
                if activeTab == .home, selectedRecipe != nil, capturedImage == nil, shootQueue.isEmpty {
                    openPoseGuide()
                } else {
                    withAnimation(.easeOut(duration: 0.32)) { activeTab = .camera }
                }
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(.white, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(activeTab == .camera ? 0.8 : 0), lineWidth: 2).padding(-5))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera")
            Button { withAnimation(.easeOut(duration: 0.32)) { activeTab = .profile } } label: {
                VStack(spacing: 4) {
                    Image(systemName: activeTab == .profile ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 21))
                    Text("Profile")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(activeTab == .profile ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
        }
        .background {
            Palette.background.opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
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
                if selectedRecipe != nil || capturedImage != nil || !sceneMatches.isEmpty || isAnalyzing {
                    Button("Start over") { reset() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .frame(height: 40)
    }

    private var landing: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Find your next shot.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                Text("Ideas for wherever you are.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondaryText)
            }

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
                Text("\(ReferenceCatalog.items.count) ideas")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }

            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(Array(ReferenceCatalog.items.enumerated()), id: \.element.id) { index, asset in
                    if let image = asset.image {
                        feedCard(asset, image: image, index: index)
                    }
                }
            }
        }
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
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
    }

    private func feedCard(_ asset: ReferenceAsset, image: UIImage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Palette.elevated)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "camera").font(.system(size: 13)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Photo idea · \(String(format: "%02d", index + 1))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer()
            }

            Button { Task { await analyze(image, scene: false) } } label: {
                GeometryReader { tile in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tile.size.width, height: tile.size.height)
                        .clipped()
                }
                .frame(height: 370)
                .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(asset.title) inspiration")

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Try this shot")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if let source = asset.source {
                        Link("\(asset.credit) · \(asset.license)", destination: source)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    } else {
                        Text("\(asset.credit) · \(asset.license)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer()
                Button { Task { await analyze(image, scene: false) } } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Try \(asset.title) shot")
            }
            Rectangle().fill(Palette.border).frame(height: 1).padding(.top, 9)
        }
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
                                    Task { await analyze(image, scene: false) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 132, height: 154)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Choose your shots")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                Spacer()
                Text("\(selectedMatches.count) selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Text("Pick one or more references for this place. Best scene matches appear first.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondaryText)
            if let scannedScene {
                Image(uiImage: scannedScene)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 138)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                    .overlay(alignment: .topLeading) { imageLabel("YOUR SCENE") }
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
                                    .frame(height: 190)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selectedMatches.contains(match.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24, weight: .medium))
                                            .shadow(radius: 3)
                                            .padding(10)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text("\(Int(min(max(match.score, 0), 1) * 100))% match")
                                            .font(.system(size: 12, weight: .bold))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(.black.opacity(0.75), in: Capsule())
                                            .padding(9)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                                Text(matchingTitle(for: match.id))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let source = ReferenceCatalog.items.first(where: { $0.id == match.id }) {
                                    Text("\(source.credit) · \(source.license)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(matchingTitle(for: match.id)), \(Int(match.score * 100)) percent match, \(selectedMatches.contains(match.id) ? "selected" : "not selected")")
                    }
                }
            }
            DisclosureGroup("Photo credits") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ReferenceCatalog.items) { asset in
                        if let source = asset.source {
                            Link(destination: source) {
                                HStack {
                                    Text("\(asset.title) · \(asset.credit) · \(asset.license)")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.secondaryText)
            .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isSceneScan ? "A shot for this place" : "Your shot plan")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                Text(recipe.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(.white)
                Text(recipe.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if let referenceImage {
                Image(uiImage: referenceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 330)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        imageLabel(isSceneScan ? "YOUR SCENE" : "REFERENCE")
                    }
            }
            if let analysis {
                Text(analysis.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            VStack(spacing: 0) {
                instruction(symbol: "iphone", title: "Camera", body: analysis?.geometry.distanceLabel ?? recipe.camera)
                rowDivider
                instruction(symbol: "figure.stand", title: "Pose", body: analysis.map { $0.poseSkeleton?.shortCue ?? "Pose not measured; use the photo as your guide." } ?? recipe.pose)
                rowDivider
                instruction(symbol: "sun.max", title: "Light", body: analysis == nil ? recipe.light : "Match the light direction in the reference.")
                rowDivider
                instruction(symbol: "square.dashed", title: "Frame", body: analysis == nil ? recipe.framing : "Place the subject where they appear in the reference.")
            }
            Button {
                openPoseGuide()
            } label: {
                Text("See pose guide")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            if isSceneScan {
                Text("Other ideas")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(ShotRecipe.presets.filter { $0.id != recipe.id }) { option in
                            Button {
                                selectedRecipe = option
                            } label: {
                                Text(option.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 11)
                                    .overlay(Capsule().stroke(.white.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 20) {
            if !shootQueue.isEmpty {
                Text("Shot \(currentShotIndex + 1) of \(shootQueue.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(shootQueue.isEmpty ? "Your shot" : "Review your shot")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(comparisonNote ?? (referenceImage == nil
                ? "Capture complete. Add a reference next time for a side-by-side comparison."
                : "Compare the subject's position, horizon, and light."))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.58))
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
                HStack(spacing: 8) {
                    compareImage(referenceImage, label: isSceneScan ? "SCENE" : "REFERENCE")
                    compareImage(image, label: "YOUR SHOT")
                }
                .frame(height: 320)
            } else {
                compareImage(image, label: "YOUR SHOT")
                    .frame(height: 420)
            }
            if let recipe = selectedRecipe {
                instruction(symbol: "scope", title: "Try one adjustment", body: recipe.framing)
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
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingShot)
                Button("Retake") {
                    capturedImage = nil
                    comparisonNote = nil
                    poseScore = nil
                    withAnimation(.easeOut(duration: 0.32)) { activeTab = .camera }
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
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                Button("Take another shot") { activeTab = .camera }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private func compareImage(_ image: UIImage, label: String) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipped()
            .overlay(alignment: .topLeading) { imageLabel(label) }
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func imageLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(12)
    }

    private func analyze(_ image: UIImage, scene: Bool) async {
        let requestID = UUID()
        flowID = requestID
        activeTab = .home
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
            let result = try await AnalysisService.analyze(image)
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
        activeTab = .camera
        withAnimation(.easeInOut(duration: 0.3)) { showingPoseTutorial = true }
    }

    private func importInspiration(_ image: UIImage, source: InspirationSource) async {
        do {
            try inspirationStore.add(image, source: source)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await analyze(image, scene: false)
    }

    private func scanScene(_ image: UIImage) async {
        let requestID = UUID()
        flowID = requestID
        activeTab = .home
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
            guard let image = reference.image else { return nil }
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
        return inspirationStore.image(for: item)
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
            let result = try await AnalysisService.analyze(image)
            guard requestID == flowID else { return }
            referenceImage = image
            analysis = result
            selectedRecipe = result.recipe
            capturedImage = nil
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
                    .background(.white, in: Capsule())
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
        if let referencePose = analysis?.poseSkeleton,
           let capturedPose = result.poseSkeleton,
           let match = PoseMatcher.compare(reference: referencePose, live: capturedPose) {
            poseScore = match.score
            comparisonNote = match.cue
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
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
                    .background(.white, in: Capsule())
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
