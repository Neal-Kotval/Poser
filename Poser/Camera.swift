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
    private var lastDetection = Date.distantPast
    private var wantsToRun = false
    private var isConfigured = false
    @Published var isReady = false
    @Published var isDemo = false
    @Published var isCapturing = false
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    @Published var message: String?
    @Published var subjectHint = "Place the subject inside the guide"
    @Published var poseScore: Int?
    @Published var poseHint = "Looking for the reference pose"
    var targetX: CGFloat {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedTargetX }
        set { targetLock.lock(); storedTargetX = newValue; targetLock.unlock() }
    }
    var targetPose: PoseSkeleton? {
        get { targetLock.lock(); defer { targetLock.unlock() }; return storedTargetPose }
        set { targetLock.lock(); storedTargetPose = newValue; targetLock.unlock() }
    }
    var onPhoto: ((UIImage) -> Void)?

    func start() {
        #if targetEnvironment(simulator)
        isDemo = true
        isReady = true
        message = nil
        #else
        queue.async { self.wantsToRun = true }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                DispatchQueue.main.async { self.message = "Allow camera access in Settings to use live guidance." }
                return
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
                guard let gravity = data?.gravity else { return }
                self?.pitch = atan2(gravity.z, -gravity.y) * 180 / .pi
                self?.roll = atan2(gravity.x, -gravity.y) * 180 / .pi
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
    let referenceImage: UIImage?
    let referenceTitle: String?
    let queueProgress: (current: Int, total: Int)?
    let embedded: Bool
    let isActive: Bool
    let isGuideOverlayVisible: Bool
    let onCapture: (UIImage) -> Void
    let onPoseGuide: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()
    @State private var showGrid = false
    @State private var showPose = true
    @State private var tutorialStep = 0

    init(mode: Mode, recipe: ShotRecipe?, targetX: CGFloat, targetPose: PoseSkeleton? = nil, shotGeometry: ShotGeometry? = nil, referenceImage: UIImage? = nil, referenceTitle: String? = nil, queueProgress: (current: Int, total: Int)? = nil, embedded: Bool = false, isActive: Bool = true, isGuideOverlayVisible: Bool = false, onCapture: @escaping (UIImage) -> Void, onPoseGuide: (() -> Void)? = nil) {
        self.mode = mode
        self.recipe = recipe
        self.targetX = targetX
        self.targetPose = targetPose
        self.shotGeometry = shotGeometry
        self.referenceImage = referenceImage
        self.referenceTitle = referenceTitle
        self.queueProgress = queueProgress
        self.embedded = embedded
        self.isActive = isActive
        self.isGuideOverlayVisible = isGuideOverlayVisible
        self.onCapture = onCapture
        self.onPoseGuide = onPoseGuide
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
                            Image(systemName: "xmark").frame(width: 42, height: 42)
                        }
                    }
                    Spacer()
                    if !embedded {
                        Text(mode == .scan ? "Scan surroundings" : "Live coach")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    Button { showGrid.toggle() } label: {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 18, weight: .regular))
                            .frame(width: 42, height: 42)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                if camera.isDemo {
                    Text("SIMULATOR PREVIEW")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.75), in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                }

                if mode == .guide, let recipe, let referenceImage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(uiImage: referenceImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 78, height: 110)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: PoserRadius.control))
                            .accessibilityLabel("Current reference photo")
                        VStack(alignment: .leading, spacing: 5) {
                            if let queueProgress {
                                Text("SHOT \(queueProgress.current) OF \(queueProgress.total)")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1)
                            }
                            Text(referenceTitle ?? recipe.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(2)
                        }
                        .padding(.top, 8)
                        Spacer(minLength: 0)
                        Button { onPoseGuide?() } label: {
                            if let targetPose {
                                MiniPoseGuide(skeleton: targetPose,
                                              geometry: shotGeometry ?? ShotGeometryEstimator.fallback(for: recipe))
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "figure.stand")
                                        .font(.system(size: 27, weight: .light))
                                    Text("SETUP GUIDE")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .tracking(1)
                                }
                                .foregroundStyle(.white)
                                .frame(width: 128, height: 110)
                                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: PoserRadius.control))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open pose and camera setup")
                    }
                    .padding(.horizontal, 18)
                }

                if mode == .guide, recipe != nil, !showPose {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkle.viewfinder")
                            .foregroundStyle(Palette.primaryText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tutorialStep == 0
                                 ? (shotGeometry?.distanceLabel ?? "Move until framing matches")
                                 : tutorialStep == 1
                                   ? (targetPose?.shortCue ?? "Use the reference to adjust your pose")
                                   : "Match the subject's position in the reference")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                            Text("Tap for next tip")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: PoserRadius.control))
                    .padding(.horizontal, 18)
                    .onTapGesture { tutorialStep = (tutorialStep + 1) % 3 }
                }
                Spacer()
                if mode == .guide, recipe != nil, camera.isReady, !camera.isDemo {
                    VStack(alignment: .leading, spacing: 8) {
                        if targetPose != nil {
                            HStack(alignment: .center, spacing: 13) {
                                Text(camera.poseScore.map { "\($0)%" } ?? "—")
                                    .font(.system(size: 31, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("POSE MATCH")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .tracking(1)
                                    Text(camera.poseHint)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(Palette.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.rectangle")
                                .foregroundStyle(Palette.primaryText)
                            Text(camera.subjectHint)
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Image(systemName: abs(camera.roll) < 3 ? "checkmark.circle.fill" : "level")
                                .foregroundStyle(abs(camera.roll) < 3 ? Palette.primaryText : Palette.secondaryText)
                            Text(abs(camera.roll) < 3 ? "Level" : "Tilt \(Int(abs(camera.roll)))° to level")
                            Spacer()
                            Button(showPose ? "Hide pose" : "Show pose") { showPose.toggle() }
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(14)
                    .background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: PoserRadius.control))
                    .padding(.horizontal, 18)
                } else if mode == .scan {
                    Text(camera.isDemo ? "Sample scene for simulator testing" : "Point at the place where you want to shoot")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .padding(14)
                        .background(Palette.background.opacity(0.85), in: Capsule())
                } else if mode == .guide, recipe == nil {
                    VStack(spacing: 4) {
                        Text("Looking for inspo?")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Take a photo of this place to find a shot")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Palette.background.opacity(0.82), in: Capsule())
                }
                Button { camera.capture() } label: {
                    Circle()
                        .stroke(.white, lineWidth: 2)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().fill(.white).frame(width: 60, height: 60))
                }
                .disabled(!camera.isReady || camera.isCapturing)
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
            if isActive { camera.start() }
        }
        .onChange(of: isActive) { _, active in
            if active { camera.start() } else { camera.stop() }
        }
        .onChange(of: queueProgress?.current) { _, _ in
            camera.targetPose = targetPose
            camera.targetX = targetX
            camera.poseScore = nil
        }
        .onChange(of: targetPose?.points) { _, _ in
            camera.targetPose = targetPose
            camera.poseScore = nil
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
