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
    var targetX: CGFloat = 0.5
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
        motion.stopDeviceMotionUpdates()
        queue.async {
            self.wantsToRun = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isReady = false }
        }
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
            DispatchQueue.main.async { self.subjectHint = "Place the subject inside the guide" }
            return
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
    let embedded: Bool
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()
    @State private var showGrid = false
    @State private var showPose = true
    @State private var tutorialStep = 0

    init(mode: Mode, recipe: ShotRecipe?, targetX: CGFloat, embedded: Bool = false, onCapture: @escaping (UIImage) -> Void) {
        self.mode = mode
        self.recipe = recipe
        self.targetX = targetX
        self.embedded = embedded
        self.onCapture = onCapture
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
                if showGrid { ThirdsGrid().ignoresSafeArea() }
                if showPose && mode == .guide && recipe != nil {
                    GeometryReader { geometry in
                        Ellipse()
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.3, dash: [7, 7]))
                            .frame(width: 180, height: 330)
                            .position(x: geometry.size.width * min(max(targetX, 0.22), 0.78), y: geometry.size.height * 0.53)
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

                if mode == .guide, let recipe {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkle.viewfinder")
                            .foregroundStyle(Palette.primaryText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text([recipe.camera, recipe.pose, recipe.framing][tutorialStep])
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(14)
                    .background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: PoserRadius.control))
                    .padding(.horizontal, 18)
                } else if mode == .scan {
                    Text(camera.isDemo ? "Sample scene for simulator testing" : "Point at the place where you want to shoot")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .padding(14)
                        .background(Palette.background.opacity(0.85), in: Capsule())
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
        }
        .onAppear {
            camera.onPhoto = { image in
                onCapture(image)
                if !embedded { dismiss() }
            }
            camera.targetX = targetX
            camera.start()
        }
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
