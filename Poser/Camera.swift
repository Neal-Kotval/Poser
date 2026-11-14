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
    @Published var scoreUsesOutline = false
    @Published var poseHint = "Looking for the reference pose"
    @Published var coachInstruction: CoachInstruction?
    @Published var liveFrameAspect: CGFloat = 3.0 / 4.0
    private var coachEnabled: Bool {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedCoachEnabled }
        set { targetLock.lock(); storedCoachEnabled = newValue; targetLock.unlock() }
    }
    /// Set on the main thread. A measured reference turns on step-by-step coaching.
    var shotSpec: ShotSpec? {
        didSet {
            targetLock.lock()
            storedTargetOutline = shotSpec?.silhouette ?? []
            storedReferenceAspect = shotSpec?.imageAspect ?? 3.0 / 4.0
            if let source = shotSpec?.focalSource,
               case .exif(let millimeters) = source, millimeters > 0 {
                storedReferenceFocalRatio = CGFloat(LensModel.phoneMainEquivalentMM / millimeters)
            } else {
                storedReferenceFocalRatio = 1
            }
            targetLock.unlock()
            coach = shotSpec.map { LiveCoach(spec: $0, referencePose: targetPose) }
            pendingReading = nil
            coachInstruction = nil
            poseScore = nil
            scoreUsesOutline = false
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
    private var referenceOutlineSnapshot: (points: [CGPoint], aspect: CGFloat, focalRatio: CGFloat) {
        targetLock.lock()
        defer { targetLock.unlock() }
        return (storedTargetOutline, storedReferenceAspect, storedReferenceFocalRatio)
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
                        self.scoreUsesOutline = false
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
            guard let reading = analyzer.analyze(sampleBuffer) else { return }
            let outline = referenceOutlineSnapshot
            let poseMatch = PoseMatcher.compare(reference: targetPose, live: reading.pose,
                                                referenceOutline: outline.points, liveOutline: reading.silhouette)
            let mappedOutline = outline.points.map {
                FrameMapping.map($0, fromAspect: outline.aspect,
                                 intoAspect: reading.frameAspect ?? 3.0 / 4.0,
                                 focalRatio: outline.focalRatio)
            }
            let frameOverlap = SilhouetteMatcher.frameOverlap(reference: mappedOutline,
                                                               live: reading.silhouette)
            DispatchQueue.main.async {
                self.pendingReading = reading
                if let aspect = reading.frameAspect { self.liveFrameAspect = aspect }
                self.poseScore = frameOverlap ?? poseMatch?.score
                self.scoreUsesOutline = frameOverlap != nil
                self.poseHint = frameOverlap.map { $0 < 65 && (poseMatch?.score ?? 0) >= 85
                    ? "Align your outline with the guide" : poseMatch?.cue ?? "Match the outline" }
                    ?? poseMatch?.cue
                    ?? (reading.pose == nil ? "Looking for the reference pose" : "Move into view to match the pose")
            }
            return
        }
        guard Date().timeIntervalSince(lastDetection) > 0.6,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetection = Date()
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        guard (try? handler.perform([request])) != nil,
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

    init(mode: Mode, recipe: ShotRecipe?, targetX: CGFloat, targetPose: PoseSkeleton? = nil, shotGeometry: ShotGeometry? = nil, shotSpec: ShotSpec? = nil, referenceImage: UIImage? = nil, referenceTitle: String? = nil, queueProgress: (current: Int, total: Int)? = nil, embedded: Bool = false, isActive: Bool = true, isGuideOverlayVisible: Bool = false, onCapture: @escaping (UIImage) -> Void, onPoseGuide: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil) {
        self.mode = mode
        self.recipe = recipe
        self.targetX = targetX
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
                   let shotSpec, shotSpec.silhouette.count > 2 {
                    GeometryReader { geometry in
                        let aligned = camera.coachInstruction?.kind == .hold &&
                            camera.scoreUsesOutline && (camera.poseScore ?? 0) >= 65
                        Path { path in
                            path.addLines(FrameMapping.cutout(for: shotSpec,
                                                              frameAspect: camera.liveFrameAspect,
                                                              viewSize: geometry.size))
                            path.closeSubpath()
                        }
                        .stroke(.white.opacity(aligned ? 0.95 : 0.7),
                                style: StrokeStyle(lineWidth: aligned ? 3 : 2, lineJoin: .round, dash: aligned ? [] : [8, 6]))
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else if showPose && mode == .guide && !isGuideOverlayVisible,
                   let guidePose = targetPose {
                    GeometryReader { geometry in
                        let guideX = geometry.size.width * min(max(targetX, 0.25), 0.75)
                        BubblePoseFigure(target: guidePose, progress: 1)
                            .opacity(0.3)
                            .frame(width: 170, height: 310)
                            .position(x: guideX, y: geometry.size.height * 0.53)
                        Text("REFERENCE POSE")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 5)
                            .position(x: guideX, y: geometry.size.height * 0.53 + 170)
                    }
                    .allowsHitTesting(false)
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
                            .font(.system(size: 25, weight: .bold))
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
                    if embedded, recipe != nil, let onStartOver {
                        Button("Start over", action: onStartOver)
                            .font(.system(size: 13, weight: .medium))
                            .frame(minHeight: 44)
                            .accessibilityHint("Discard the current shoot and return to the camera")
                    }
                    if !embedded {
                        Text(mode == .scan ? "Scan surroundings" : "Live coach")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    Button { showGrid.toggle() } label: {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(showGrid ? Palette.primaryText : Palette.secondaryText)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Grid")
                    .accessibilityValue(showGrid ? "On" : "Off")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                if mode == .guide, let recipe, let referenceImage {
                    HStack(alignment: .center, spacing: 12) {
                        Image(uiImage: referenceImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                            .accessibilityLabel("Current reference photo")
                        VStack(alignment: .leading, spacing: 4) {
                            if let queueProgress {
                                Text("SHOT \(queueProgress.current) OF \(queueProgress.total)")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1)
                            }
                            Text(referenceTitle ?? recipe.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(2)
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
                if mode == .guide, recipe != nil, camera.isReady, !camera.isDemo {
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
                        if let score = camera.poseScore,
                           targetPose != nil || (shotSpec?.silhouette.count ?? 0) >= 3 {
                            VStack(spacing: 1) {
                                Text(camera.scoreUsesOutline ? "OUTLINE" : "POSE")
                                    .font(.system(size: 8, weight: .bold))
                                    .tracking(0.5)
                                Text("\(score)%")
                                    .font(.system(size: 15, weight: .bold))
                                    .monospacedDigit()
                            }
                            .accessibilityLabel(camera.scoreUsesOutline
                                ? "Outline overlap \(score) percent" : "Pose match \(score) percent")
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
                .padding(.bottom, embedded ? 90 : 30)
            }
            .foregroundStyle(.white)
            .opacity(isGuideOverlayVisible ? 0 : 1)
            .allowsHitTesting(!isGuideOverlayVisible)
        }
        .onAppear {
            camera.onPhoto = { image in
                onCapture(image)
                if !embedded { dismiss() }
            }
            camera.targetX = targetX
            camera.targetPose = targetPose
            camera.shotSpec = shotSpec
            if isActive { camera.start() }
        }
        .onChange(of: isActive) { _, active in
            if active { camera.start() } else { camera.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isActive {
                camera.start()
            } else if phase != .active {
                camera.stop()
            }
        }
        .onChange(of: queueProgress?.current) { _, _ in
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
        .onChange(of: shotSpec?.distanceMeters) { _, _ in camera.shotSpec = shotSpec }
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
