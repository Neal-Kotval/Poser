import SwiftUI
import AVFoundation
import CoreMotion
import Photos
import Vision
import ImageIO

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "poser.camera")
    private let videoQueue = DispatchQueue(label: "poser.camera.vision")
    private let motion = CMMotionManager()
    private let targetLock = NSLock()
    private var storedTargetX: CGFloat = 0.5
    private var storedTargetPose: PoseSkeleton?
    private var storedTargetOutline: [CGPoint] = []
    private var storedGuidePlacement = PoseGuidePlacement.identity
    private var storedReferenceAspect: CGFloat = 3.0 / 4.0
    private var storedReferenceFocalRatio: CGFloat = 1
    private var storedCoachEnabled = false
    private let analyzer = LiveFrameAnalyzer(minimumInterval: 0.3)
    private var coach: LiveCoach?
    private var pendingReading: LiveReading?
    private var lastDetection = Date.distantPast
    private var wantsToRun = false
    private var isConfigured = false
    @Published var isReady = false
    @Published var isDemo = false
    @Published var isCapturing = false
    @Published var isPermissionDenied = false
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    @Published var message: String?
    @Published var subjectHint = "Place the subject inside the guide"
    @Published var poseScore: Int?
    @Published var outlineOverlap: Int?
    @Published var poseHint = "Looking for the reference pose"
    @Published var coachInstruction: CoachInstruction?
    @Published var liveFrameAspect: CGFloat = 3.0 / 4.0
    private var coachEnabled: Bool {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedCoachEnabled }
        set { targetLock.lock(); storedCoachEnabled = newValue; targetLock.unlock() }
    }
    var guidePlacement = PoseGuidePlacement.identity {
        didSet {
            let current = shotSpec
            shotSpec = current
        }
    }
    /// Set on the main thread. A measured reference turns on step-by-step coaching.
    var shotSpec: ShotSpec? {
        didSet {
            targetLock.lock()
            storedTargetOutline = shotSpec?.silhouette ?? []
            storedGuidePlacement = guidePlacement
            storedReferenceAspect = shotSpec?.imageAspect ?? 3.0 / 4.0
            if let source = shotSpec?.focalSource,
               case .exif(let millimeters) = source, millimeters > 0 {
                storedReferenceFocalRatio = CGFloat(LensModel.phoneMainEquivalentMM / millimeters)
            } else {
                storedReferenceFocalRatio = 1
            }
            targetLock.unlock()
            coach = shotSpec.map { LiveCoach(spec: $0, referencePose: targetPose, liveAspect: liveFrameAspect,
                                             guidePlacement: guidePlacement) }
            if let center = coach?.targetBox?.midX { targetX = center }
            pendingReading = nil
            coachInstruction = nil
            poseScore = nil
            outlineOverlap = nil
            coachEnabled = coach != nil
        }
    }
    var targetX: CGFloat {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedTargetX }
        set { targetLock.lock(); storedTargetX = newValue; targetLock.unlock() }
    }
    var targetPose: PoseSkeleton? {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedTargetPose }
        set { targetLock.lock(); storedTargetPose = newValue; targetLock.unlock() }
    }
    private var referenceOutlineSnapshot: (points: [CGPoint], aspect: CGFloat, focalRatio: CGFloat, placement: PoseGuidePlacement) {
        targetLock.lock()
        defer { targetLock.unlock() }
        return (storedTargetOutline, storedReferenceAspect, storedReferenceFocalRatio, storedGuidePlacement)
    }
    var onPhoto: ((UIImage) -> Void)?

    func start() {
        #if targetEnvironment(simulator)
        isDemo = true
        isReady = true
        isPermissionDenied = false
        message = nil
        #else
        queue.async { self.wantsToRun = true }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                DispatchQueue.main.async {
                    self.isReady = false
                    self.isPermissionDenied = true
                    self.message = "Allow camera access in Settings to use live guidance."
                }
                return
            }
            DispatchQueue.main.async {
                self.isPermissionDenied = false
                self.message = nil
            }
            self.queue.async {
                guard self.wantsToRun else { return }
                if !self.isConfigured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          let input = try? AVCaptureDeviceInput(device: camera),
                          self.session.canAddInput(input), self.session.canAddOutput(self.output),
                          self.session.canAddOutput(self.videoOutput) else {
                        self.session.commitConfiguration()
                        DispatchQueue.main.async { self.message = "A camera is not available on this device." }
                        return
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.output)
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                    self.session.addOutput(self.videoOutput)
                    if let connection = self.videoOutput.connection(with: .video),
                       connection.isCameraIntrinsicMatrixDeliverySupported {
                        connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                    }
                    self.session.commitConfiguration()
                    self.isConfigured = true
                }
                self.session.startRunning()
                DispatchQueue.main.async { self.isReady = true }
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.12
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let gravity = data?.gravity else { return }
                self.pitch = atan2(gravity.z, -gravity.y) * 180 / .pi
                self.roll = atan2(gravity.x, -gravity.y) * 180 / .pi
                if let coach = self.coach {
                    self.coachInstruction = coach.update(reading: self.pendingReading,
                                                         pitchDegrees: self.pitch, rollDegrees: self.roll)
                    self.pendingReading = nil
                    if !coach.hasFreshReading {
                        self.poseScore = nil
                        self.outlineOverlap = nil
                        self.poseHint = "Looking for the reference pose"
                    }
                }
            }
        }
        #endif
    }

    func stop() {
        #if targetEnvironment(simulator)
        isReady = false
        #else
        motion.stopDeviceMotionUpdates()
        queue.async {
            self.wantsToRun = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isReady = false }
        }
        #endif
    }

    func capture() {
        guard isReady, !isCapturing else { return }
        isCapturing = true
        #if targetEnvironment(simulator)
        if isDemo {
            defer { isCapturing = false }
            guard let image = UIImage(named: "InspirationPortrait") else {
                message = "The simulator preview image is missing."
                return
            }
            onPhoto?(image)
            return
        }
        #endif
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.message = error.localizedDescription
            }
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.message = "The camera could not process this photo. Try again."
            }
            return
        }
        DispatchQueue.main.async {
            self.isCapturing = false
            self.onPhoto?(image)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if coachEnabled {
            guard let reading = analyzer.analyze(sampleBuffer, targetX: targetX) else { return }
            let outline = referenceOutlineSnapshot
            let scores = Self.scoreLivePose(referencePose: targetPose, livePose: reading.pose,
                                            referenceOutline: outline.points, liveOutline: reading.silhouette,
                                            referenceAspect: outline.aspect,
                                            liveAspect: reading.frameAspect ?? 3.0 / 4.0,
                                            focalRatio: outline.focalRatio, placement: outline.placement)
            DispatchQueue.main.async {
                self.pendingReading = reading
                if let aspect = reading.frameAspect { self.liveFrameAspect = aspect }
                self.poseScore = scores.pose?.score
                self.outlineOverlap = scores.frameOverlap
                self.poseHint = scores.frameOverlap.map { $0 < 65 && (scores.pose?.score ?? 0) >= 85
                    ? "Adjust your position to match the reference" : scores.pose?.cue ?? "Match the reference pose" }
                    ?? scores.pose?.cue
                    ?? (reading.pose == nil ? "Looking for the reference pose" : "Move into view to match the pose")
            }
            return
        }
        guard Date().timeIntervalSince(lastDetection) > 0.6,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetection = Date()
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        guard VisionRunner.perform(request, on: handler) == nil,
              let person = request.results?.first else {
            DispatchQueue.main.async {
                self.subjectHint = "Place the subject inside the guide"
                self.poseScore = nil
                self.poseHint = "Looking for the reference pose"
            }
            return
        }
        let poseMatch = targetPose.flatMap { target in
            PoseSkeleton.detected(from: person).flatMap { PoseMatcher.compare(reference: target, live: $0) }
        }
        DispatchQueue.main.async {
            self.poseScore = poseMatch?.score
            self.poseHint = poseMatch?.cue ?? "Move into view to match the pose"
        }
        let nose = try? person.recognizedPoint(.nose)
        let left = try? person.recognizedPoint(.leftShoulder)
        let right = try? person.recognizedPoint(.rightShoulder)
        let subjectX: CGFloat?
        if let nose, nose.confidence > 0.3 {
            subjectX = nose.location.x
        } else if let left, let right, left.confidence > 0.3, right.confidence > 0.3 {
            subjectX = (left.location.x + right.location.x) / 2
        } else {
            subjectX = nil
        }
        guard let subjectX else {
            DispatchQueue.main.async { self.subjectHint = "Place the subject inside the guide" }
            return
        }
        let delta = subjectX - targetX
        let hint = abs(delta) < 0.1 ? "Subject is in position" :
            (delta < 0 ? "Move subject a little right" : "Move subject a little left")
        DispatchQueue.main.async { self.subjectHint = hint }
    }

    static func scoreLivePose(referencePose: PoseSkeleton?, livePose: PoseSkeleton?,
                              referenceOutline: [CGPoint], liveOutline: [CGPoint],
                              referenceAspect: CGFloat, liveAspect: CGFloat,
                              focalRatio: CGFloat, placement: PoseGuidePlacement = .identity) -> (pose: PoseMatch?, frameOverlap: Int?) {
        let pose = PoseMatcher.compare(reference: referencePose, live: livePose,
                                       referenceOutline: referenceOutline, liveOutline: liveOutline)
        let mappedOutline = FrameMapping.mapOutline(referenceOutline, fromAspect: referenceAspect,
                                                    intoAspect: liveAspect, focalRatio: focalRatio)
        let frameOverlap = SilhouetteMatcher.frameOverlap(reference: placement.applying(to: mappedOutline), live: liveOutline)
        return (pose, frameOverlap)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.videoGravity = .resizeAspectFill
        view.layer.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
}

struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    let x = geometry.size.width * fraction
                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

struct CameraScreen: View {
    enum Mode { case scan, guide }
    let mode: Mode
    let recipe: ShotRecipe?
    let targetX: CGFloat
    let targetPose: PoseSkeleton?
    let shotGeometry: ShotGeometry?
    let shotSpec: ShotSpec?
    let referenceImage: UIImage?
    let referenceTitle: String?
    let queueProgress: (current: Int, total: Int)?
    let embedded: Bool
    let isActive: Bool
    let isGuideOverlayVisible: Bool
    let onCapture: (UIImage) -> Void
    let onPoseGuide: (() -> Void)?
    let onStartOver: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraModel()
    @State private var showGrid = false
    @State private var showPose = true
    @State private var showReferencePreview = false
    @Binding var guidePlacement: PoseGuidePlacement

    init(mode: Mode, recipe: ShotRecipe?, targetX: CGFloat, guidePlacement: Binding<PoseGuidePlacement>, targetPose: PoseSkeleton? = nil, shotGeometry: ShotGeometry? = nil, shotSpec: ShotSpec? = nil, referenceImage: UIImage? = nil, referenceTitle: String? = nil, queueProgress: (current: Int, total: Int)? = nil, embedded: Bool = false, isActive: Bool = true, isGuideOverlayVisible: Bool = false, onCapture: @escaping (UIImage) -> Void, onPoseGuide: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil) {
        self.mode = mode
        self.recipe = recipe
        self.targetX = targetX
        self._guidePlacement = guidePlacement
        self.targetPose = targetPose
        self.shotGeometry = shotGeometry
        self.shotSpec = shotSpec
        self.referenceImage = referenceImage
        self.referenceTitle = referenceTitle
        self.queueProgress = queueProgress
        self.embedded = embedded
        self.isActive = isActive
        self.isGuideOverlayVisible = isGuideOverlayVisible
        self.onCapture = onCapture
        self.onPoseGuide = onPoseGuide
        self.onStartOver = onStartOver
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if camera.isReady {
                if camera.isDemo {
                    GeometryReader { geometry in
                        Image("InspirationPortrait")
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                } else {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                }
                if showGrid && !isGuideOverlayVisible { ThirdsGrid().ignoresSafeArea() }
                if showPose && mode == .guide && !isGuideOverlayVisible,
                   (shotSpec?.silhouette.count ?? 0) > 2 || targetPose != nil {
                    AdjustableCameraGuide(spec: shotSpec, pose: targetPose, targetX: targetX,
                                          frameAspect: camera.liveFrameAspect,
                                          aligned: camera.coachInstruction?.kind == .hold && (camera.outlineOverlap ?? 0) >= 65,
                                          placement: $guidePlacement)
                        .ignoresSafeArea()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera")
                        .font(.system(size: 33, weight: .ultraLight))
                    Text(camera.message ?? "Opening camera…")
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                    if camera.isPermissionDenied {
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 140, minHeight: 44)
                        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                    }
                }
                .foregroundStyle(Palette.primaryText)
                .padding(30)
            }
            VStack {
                HStack {
                    if embedded {
                        Text("poser")
                            .font(PoserType.wordmark)
                            .tracking(-1.5)
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Close camera")
                    }
                    Spacer()
                    if !embedded {
                        Text(mode == .scan ? "Scan surroundings" : "Live coach")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    Button { showGrid.toggle() } label: {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(showGrid ? Palette.primaryText : Palette.secondaryText)
                            .frame(width: 32, height: 32)
                            .poserGlass(cornerRadius: 16, interactive: true)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Grid")
                    .accessibilityValue(showGrid ? "On" : "Off")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                if mode == .guide, recipe != nil, let referenceImage {
                    HStack(alignment: .center, spacing: 8) {
                        if let onStartOver {
                            Button(action: onStartOver) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back to camera")
                        }
                        Button { showReferencePreview = true } label: {
                            Image(uiImage: referenceImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                                .contentShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand reference photo")
                        if let queueProgress {
                            Text("SHOT \(queueProgress.current) OF \(queueProgress.total)")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1)
                        }
                        Spacer(minLength: 0)
                        Button { onPoseGuide?() } label: {
                            Image(systemName: "figure.stand")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .poserGlass(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open pose and camera setup")
                    }
                    .padding(.horizontal, 18)
                }
                Spacer()
                if mode == .guide, recipe != nil, camera.isReady {
                    HStack(spacing: 10) {
                        if let instruction = camera.coachInstruction {
                            Image(systemName: instruction.symbol)
                                .font(.system(size: 19, weight: .semibold))
                            Text(instruction.text)
                                .font(.system(size: 15, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Image(systemName: abs(camera.roll) < 3 ? "person.crop.rectangle" : "level")
                                .font(.system(size: 19, weight: .medium))
                            Text(abs(camera.roll) < 3 ? (targetPose == nil ? camera.subjectHint : camera.poseHint)
                                 : "Tilt \(Int(abs(camera.roll)))° to level")
                                .font(.system(size: 15, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if targetPose != nil || (shotSpec?.silhouette.count ?? 0) >= 3 {
                            VStack(spacing: 1) {
                                Text("POSE")
                                    .font(.system(size: 8, weight: .bold))
                                    .tracking(0.5)
                                Text(camera.poseScore.map { "\($0)%" } ?? "—")
                                    .font(.system(size: 15, weight: .bold))
                                    .monospacedDigit()
                            }
                            .accessibilityLabel(camera.poseScore.map { "Pose match \($0) percent" }
                                ?? "Looking for pose match")
                        }
                        Button { showPose.toggle() } label: {
                            Image(systemName: showPose ? "eye.slash" : "eye")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(showPose ? "Hide pose" : "Show pose")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .poserGlass()
                    .padding(.horizontal, 18)
                } else if mode == .scan {
                    Text(camera.isDemo ? "Sample scene for simulator testing" : "Point at the place where you want to shoot")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .padding(14)
                        .poserGlass()
                } else if mode == .guide, recipe == nil {
                    Text("Scan this place to find a shot")
                    .font(.system(size: 14, weight: .medium))
                    .padding(14)
                    .poserGlass()
                }
                Button { camera.capture() } label: {
                    Circle()
                        .stroke(.white, lineWidth: 2)
                        .frame(width: 72, height: 72)
                        .overlay {
                            if camera.isCapturing {
                                ProgressView()
                                    .tint(.black)
                                    .frame(width: 60, height: 60)
                                    .background(.white, in: Circle())
                            } else {
                                Circle().fill(.white).frame(width: 60, height: 60)
                            }
                        }
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .accessibilityLabel(mode == .scan || recipe == nil ? "Scan this scene" : "Take photo")
                .accessibilityHint(camera.isCapturing ? "Processing photo" : "Double tap to capture")
                .padding(.top, 17)
                .padding(.bottom, embedded ? 140 : 30)
            }
            .foregroundStyle(.white)
            .opacity(isGuideOverlayVisible ? 0 : 1)
            .allowsHitTesting(!isGuideOverlayVisible)
        }
        .sheet(isPresented: $showReferencePreview) {
            if let referenceImage {
                CameraReferencePreview(image: referenceImage)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
                    .presentationCornerRadius(28)
            }
        }
        .onAppear {
            camera.onPhoto = { image in
                onCapture(image)
                if !embedded { dismiss() }
            }
            camera.targetX = targetX
            camera.targetPose = targetPose
            camera.guidePlacement = guidePlacement
            camera.shotSpec = shotSpec
            if isActive { camera.start() }
        }
        .onChange(of: isActive) { _, active in
            if active { camera.start() }
            else {
                showReferencePreview = false
                camera.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isActive {
                camera.start()
            } else if phase != .active {
                camera.stop()
            }
        }
        .onChange(of: queueProgress?.current) { _, _ in
            guidePlacement = .identity
            camera.targetPose = targetPose
            camera.targetX = targetX
            camera.shotSpec = shotSpec
            camera.poseScore = nil
        }
        .onChange(of: targetPose?.points) { _, _ in
            camera.targetPose = targetPose
            camera.shotSpec = shotSpec
            camera.poseScore = nil
        }
        .onChange(of: shotSpec) { _, newValue in
            guidePlacement = .identity
            camera.guidePlacement = .identity
            camera.shotSpec = newValue
        }
        .onChange(of: guidePlacement) { _, placement in camera.guidePlacement = placement }
        .onChange(of: referenceImage) { _, _ in
            guidePlacement = .identity
            camera.guidePlacement = .identity
            showReferencePreview = false
        }
        .onChange(of: targetX) { _, newValue in camera.targetX = newValue }
        .onDisappear { camera.stop() }
        .alert("Camera issue", isPresented: Binding(
            get: { camera.isReady && camera.message != nil },
            set: { if !$0 { camera.message = nil } }
        )) {
            Button("OK", role: .cancel) { camera.message = nil }
        } message: { Text(camera.message ?? "") }
    }
}

struct CameraGuideInteractionFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

private struct AdjustableCameraGuide: View {
    let spec: ShotSpec?
    let pose: PoseSkeleton?
    let targetX: CGFloat
    let frameAspect: CGFloat
    let aligned: Bool
    @Binding var placement: PoseGuidePlacement
    @GestureState private var translation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var snapLines = PoseGuideSnapping.Lines()

    private func basePoints(in size: CGSize) -> [CGPoint] {
        if let spec, spec.silhouette.count > 2 {
            let ratio: CGFloat
            if case .exif(let mm) = spec.focalSource, mm > 0 {
                ratio = CGFloat(LensModel.phoneMainEquivalentMM / mm)
            } else { ratio = 1 }
            return FrameMapping.mapOutline(spec.silhouette, fromAspect: spec.imageAspect,
                                            intoAspect: frameAspect, focalRatio: ratio)
        }
        let center = CGPoint(x: size.width * min(max(targetX, 0.25), 0.75), y: size.height * 0.53)
        return [CGPoint(x: center.x - 85, y: center.y - 155),
                CGPoint(x: center.x + 85, y: center.y - 155),
                CGPoint(x: center.x + 85, y: center.y + 155),
                CGPoint(x: center.x - 85, y: center.y + 155)].map {
            FrameMapping.framePoint($0, frameAspect: frameAspect, viewSize: size)
        }
    }

    private func adjusted(drag: CGSize, zoom: CGFloat, base: CGRect, visible: CGRect, size: CGSize) -> PoseGuidePlacement {
        let delta = FrameMapping.frameTranslation(drag, frameAspect: frameAspect, viewSize: size)
        return PoseGuidePlacement(scale: placement.scale * zoom,
                                  offset: CGSize(width: placement.offset.width + delta.width,
                                                 height: placement.offset.height + delta.height))
            .constrained(baseBounds: base, visibleBounds: visible)
    }

    private func snapped(drag: CGSize, zoom: CGFloat, base: CGRect, visible: CGRect, size: CGSize) -> PoseGuideSnapping.Result {
        let raw = adjusted(drag: drag, zoom: zoom, base: base, visible: visible, size: size)
        guard drag != .zero else { return .init(placement: raw, lines: .init()) }
        let threshold = FrameMapping.frameTranslation(CGSize(width: 12, height: 12), frameAspect: frameAspect, viewSize: size)
        return PoseGuideSnapping.snap(raw, base: base, viewport: visible,
                                      threshold: threshold, retaining: snapLines)
    }

    var body: some View {
        GeometryReader { geometry in
            let points = basePoints(in: geometry.size)
            let base = FrameMapping.boundingBox(of: points) ?? .zero
            let topLeft = FrameMapping.framePoint(CGPoint(x: 16, y: 16), frameAspect: frameAspect, viewSize: geometry.size)
            let bottomRight = FrameMapping.framePoint(CGPoint(x: geometry.size.width - 16, y: geometry.size.height - 16),
                                                      frameAspect: frameAspect, viewSize: geometry.size)
            let visible = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            let snap = snapped(drag: translation, zoom: magnification, base: base, visible: visible, size: geometry.size)
            let current = snap.placement
            let screenPoints = current.applying(to: points).map {
                FrameMapping.viewPoint($0, frameAspect: frameAspect, viewSize: geometry.size)
            }
            let bounds = FrameMapping.boundingBox(of: screenPoints) ?? .zero
            let committedPoints = placement.applying(to: points).map {
                FrameMapping.viewPoint($0, frameAspect: frameAspect, viewSize: geometry.size)
            }
            let committedBounds = (FrameMapping.boundingBox(of: committedPoints) ?? .zero).insetBy(dx: -24, dy: -24)
            let container = geometry.frame(in: .named("homePager"))
            let isAligned = aligned && translation == .zero && magnification == 1

            ZStack {
                Path { path in
                    if let x = snap.lines.vertical {
                        let point = FrameMapping.viewPoint(CGPoint(x: x, y: 0), frameAspect: frameAspect, viewSize: geometry.size)
                        path.move(to: CGPoint(x: point.x, y: 0))
                        path.addLine(to: CGPoint(x: point.x, y: geometry.size.height))
                    }
                    if let y = snap.lines.horizontal {
                        let point = FrameMapping.viewPoint(CGPoint(x: 0, y: y), frameAspect: frameAspect, viewSize: geometry.size)
                        path.move(to: CGPoint(x: 0, y: point.y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: point.y))
                    }
                }
                .stroke(.cyan.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if (spec?.silhouette.count ?? 0) > 2 {
                    Path { path in
                        path.addLines(screenPoints)
                        path.closeSubpath()
                    }
                    .stroke(.white.opacity(isAligned ? 0.95 : 0.7),
                            style: StrokeStyle(lineWidth: isAligned ? 3 : 2,
                                               lineJoin: .round, dash: isAligned ? [] : [8, 6]))
                    .allowsHitTesting(false)
                } else if let pose {
                    BubblePoseFigure(target: pose, progress: 1)
                        .opacity(0.3)
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .frame(width: bounds.width + 48, height: bounds.height + 48)
                    .contentShape(Rectangle())
                    .position(x: bounds.midX, y: bounds.midY)
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("cameraGuideCanvas"))
                            .simultaneously(with: MagnificationGesture())
                            .updating($translation) { value, state, _ in state = value.first?.translation ?? .zero }
                            .updating($magnification) { value, state, _ in state = value.second ?? 1 }
                            .onEnded { value in
                                placement = snapped(drag: value.first?.translation ?? .zero, zoom: value.second ?? 1,
                                                    base: base, visible: visible, size: geometry.size).placement
                                snapLines = .init()
                            }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { placement = .identity })
                    .accessibilityElement()
                    .accessibilityLabel("Adjust pose outline")
                    .accessibilityHint("Drag to move. Pinch to resize. Double tap to reset.")
                    .accessibilityValue("\(Int(current.scale * 100)) percent size")
                    .accessibilityAdjustableAction { direction in
                        var next = placement
                        switch direction {
                        case .increment: next.scale += 0.1
                        case .decrement: next.scale -= 0.1
                        @unknown default: break
                        }
                        placement = next.constrained(baseBounds: base, visibleBounds: visible)
                    }
                    .accessibilityAction { placement = .identity }
                    .accessibilityAction(named: Text("Reset pose outline")) { placement = .identity }
            }
            .onChange(of: snap.lines) { old, new in
                if (new.vertical != nil && old.vertical != new.vertical)
                    || (new.horizontal != nil && old.horizontal != new.horizontal) {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                snapLines = new
            }
            .preference(key: CameraGuideInteractionFrameKey.self,
                        value: committedBounds.offsetBy(dx: container.minX, dy: container.minY))
        }
        .coordinateSpace(name: "cameraGuideCanvas")
    }
}

private struct CameraReferencePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .accessibilityLabel("Reference photo")
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .poserGlass(cornerRadius: 22, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close reference photo")
                }
                .padding(16)
            }
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
        }
    }
}
