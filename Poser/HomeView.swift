import SwiftUI
import PhotosUI

struct HomeView: View {
    private enum Tab { case camera, home }
    private let featuredID = UUID(uuidString: "D9355526-A2BC-4941-9EB4-E3F60E85859D")!

    @State private var activeTab: Tab = .camera
    @StateObject private var inspirationStore = InspirationStore()
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

    var body: some View {
        NavigationStack {
            Group {
                if activeTab == .camera {
                    CameraScreen(
                        mode: .guide,
                        recipe: selectedRecipe,
                        targetX: analysis?.subjectPoint?.x ?? 0.5,
                        targetPose: analysis?.poseSkeleton,
                        embedded: true
                    ) { image in
                        capturedImage = image
                        comparisonNote = nil
                        poseScore = nil
                        activeTab = .home
                        Task { await compare(image) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            header
                            if let capturedImage {
                                comparison(capturedImage)
                            } else if !sceneMatches.isEmpty {
                                sceneMatchResults
                            } else if let selectedRecipe {
                                recipeDetail(selectedRecipe)
                            } else if isAnalyzing {
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
            }
            .background(Palette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { throw AnalysisError.invalidImage }
                    await importInspiration(image, source: .photoLibrary)
                    selectedPhoto = nil
                } catch { errorMessage = error.localizedDescription }
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
        .fullScreenCover(isPresented: $showingPoseTutorial) {
            if let selectedRecipe {
                PoseTutorialView(referenceImage: referenceImage, analysis: analysis, recipe: selectedRecipe) {
                    showingPoseTutorial = false
                    activeTab = .camera
                }
            }
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

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button { activeTab = .home } label: {
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
                if activeTab == .home, selectedRecipe != nil, capturedImage == nil {
                    showingPoseTutorial = true
                } else {
                    activeTab = .camera
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
            Color.clear.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
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
                if selectedRecipe != nil || capturedImage != nil {
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
            Button {
                if let image = UIImage(named: "InspirationPortrait") {
                    Task { await analyze(image, scene: false) }
                }
            } label: {
                Image("InspirationPortrait")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 410)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                            .frame(height: 200)
                    }
                    .overlay(alignment: .bottomLeading) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("INSPIRATION")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.5)
                                Text("Street portrait")
                                    .font(.system(size: 24, weight: .bold))
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(18)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
            }
            .buttonStyle(.plain)
            Text("Make your own")
                .font(PoserType.title)
                .foregroundStyle(.white)
            VStack(spacing: 0) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    actionRow(symbol: "photo", title: "Choose a photo", detail: "Use a reference from your library")
                }
                .buttonStyle(.plain)
                rowDivider
                Button { showingLink = true } label: {
                    actionRow(symbol: "link", title: "Paste a link", detail: "Pinterest, Instagram, or an image URL")
                }
                .buttonStyle(.plain)
                rowDivider
                Button { showingScan = true } label: {
                    actionRow(symbol: "viewfinder", title: "Scan this place", detail: "Get an idea for your surroundings")
                }
                .buttonStyle(.plain)
            }
            savedInspiration
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
            Text("Ideas for this place")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("These saved shots look closest to what your camera saw. Choose one to get a pose and framing plan.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondaryText)
            if let scannedScene {
                Image(uiImage: scannedScene)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                    .overlay(alignment: .topLeading) { imageLabel("YOUR SCENE") }
            }
            ForEach(sceneMatches) { match in
                if let image = matchingImage(for: match.id) {
                    Button {
                        Task { await analyze(image, scene: false) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 78, height: 94)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(matchingTitle(for: match.id))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(match.explanation)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.secondaryText)
                                    .multilineTextAlignment(.leading)
                                Text("\(Int(min(max(match.score, 0), 1) * 100))% scene match")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .padding(11)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.image))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rowDivider: some View {
        Color.white.opacity(0.16)
            .frame(height: 1)
            .padding(.leading, 40)
    }

    private func actionRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .contentShape(Rectangle())
    }

    private var analyzingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView().tint(.white)
            Text("Reading your photo")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Finding the subject, framing, and light.")
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
                instruction(symbol: "iphone", title: "Camera", body: recipe.camera)
                rowDivider
                instruction(symbol: "figure.stand", title: "Pose", body: recipe.pose)
                rowDivider
                instruction(symbol: "sun.max", title: "Light", body: recipe.light)
                rowDivider
                instruction(symbol: "square.dashed", title: "Frame", body: recipe.framing)
            }
            Button {
                showingPoseTutorial = true
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
            Text("Your shot")
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
        activeTab = .home
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
            analysis = result
            selectedRecipe = result.recipe
        } catch { errorMessage = error.localizedDescription }
        isAnalyzing = false
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
        activeTab = .home
        scannedScene = image
        sceneMatches = []
        capturedImage = nil
        selectedRecipe = nil
        referenceImage = nil
        analysis = nil
        isAnalyzing = true

        var candidates: [SceneCandidate] = []
        if let featured = UIImage(named: "InspirationPortrait") {
            candidates.append(SceneCandidate(id: featuredID, image: featured))
        }
        for item in inspirationStore.items {
            if let inspiration = inspirationStore.image(for: item) {
                candidates.append(SceneCandidate(id: item.id, image: inspiration))
            }
        }
        let matches = await SceneMatcher.rank(scene: image, candidates: candidates)
        if matches.isEmpty {
            await analyze(image, scene: true)
        } else {
            sceneMatches = matches
            isAnalyzing = false
        }
    }

    private func matchingImage(for id: UUID) -> UIImage? {
        if id == featuredID { return UIImage(named: "InspirationPortrait") }
        guard let item = inspirationStore.items.first(where: { $0.id == id }) else { return nil }
        return inspirationStore.image(for: item)
    }

    private func matchingTitle(for id: UUID) -> String {
        if id == featuredID { return "Street portrait" }
        return inspirationStore.items.first(where: { $0.id == id })?.title ?? "Saved inspiration"
    }

    private func compare(_ image: UIImage) async {
        guard let result = try? await AnalysisService.analyze(image) else { return }
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
