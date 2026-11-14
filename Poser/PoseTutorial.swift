import SwiftUI

struct ReferenceStartingSetup {
    var distanceMeters: Double
    var heightMeters: Double
    var tiltDegrees: Double
    let distanceFromFace: Bool

    init(spec: ShotSpec? = nil, faceDistanceMeters: Double? = nil) {
        let faceEstimate = spec?.distanceMeters == nil ? faceDistanceMeters : nil
        distanceMeters = min(8, max(0.3, spec?.distanceMeters ?? faceEstimate ?? 2.5))
        heightMeters = min(2.2, max(0.3, spec?.cameraHeightMeters ?? 1.5))
        tiltDegrees = min(35, max(-35, spec?.pitchDegrees ?? 0))
        distanceFromFace = faceEstimate != nil
    }

    mutating func apply(_ plan: GeminiReferencePlan, preserving spec: ShotSpec) {
        guard plan.hasPerson else { return }
        if spec.distanceMeters == nil && !distanceFromFace {
            switch plan.distance {
            case .close: distanceMeters = 1.2
            case .medium: distanceMeters = 2.5
            case .far: distanceMeters = 4
            case .unknown: break
            }
        }
        if spec.cameraHeightMeters == nil {
            switch plan.cameraLevel {
            case .ground: heightMeters = 0.35
            case .knee: heightMeters = 0.6
            case .hip: heightMeters = 1
            case .chest: heightMeters = 1.3
            case .eye: heightMeters = plan.poseStyle == .seated ? 1.2 : 1.6
            case .overhead: heightMeters = 2
            case .unknown: break
            }
        }
        if spec.pitchDegrees == nil {
            switch plan.tilt {
            case .up: tiltDegrees = 10
            case .level: tiltDegrees = 0
            case .down: tiltDegrees = -10
            case .unknown: break
            }
        }
    }
}

struct PoseTutorialView: View {
    let analysis: PhotoAnalysis?
    let recipe: ShotRecipe
    let referenceImage: UIImage?
    let referencePlan: GeminiReferencePlan?
    @Binding var startingSetup: ReferenceStartingSetup
    let onContinue: () -> Void
    let onClose: () -> Void

    private var skeleton: PoseSkeleton {
        if let measured = analysis?.poseSkeleton { return measured }
        if let referencePlan, referencePlan.hasPerson {
            return .illustration(for: referencePlan.poseStyle, recipe: recipe)
        }
        return .example(for: recipe)
    }

    private var shotGeometry: ShotGeometry {
        if let analysis, analysis.shotSpec.source == .pose3D { return analysis.geometry }
        return ShotGeometry(cameraHeightMeters: startingSetup.heightMeters,
                            distanceMeters: startingSetup.distanceMeters,
                            tiltDegrees: Int(startingSetup.tiltDegrees.rounded()),
                            inferredFromPose: false, spec: analysis?.shotSpec)
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Button { onClose() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .poserGlass(interactive: true)
                        }
                        .accessibilityLabel("Close pose guide")
                        Spacer()
                        Text("poser")
                            .font(PoserType.wordmark)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.top, 12)

                    ScrollView {
                        VStack(spacing: PoserSpace.regular) {
                            Text(analysis?.poseSkeleton == nil ? "POSE STARTING POINT" : "MATCH THIS POSE")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .tracking(2)
                                .multilineTextAlignment(.center)

                            if let referencePlan {
                                Text(referencePlan.summary)
                                    .font(PoserType.supporting)
                                    .foregroundStyle(Palette.secondaryText)
                                    .multilineTextAlignment(.center)
                            }

                            if let referenceImage, analysis?.poseSkeleton == nil {
                                Image(uiImage: referenceImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 170)
                                    .clipShape(RoundedRectangle(cornerRadius: PoserRadius.image))
                                    .accessibilityLabel("Reference photo")
                            }

                            PoseDiagramView(skeleton: skeleton, geometry: shotGeometry,
                                            illustrativeFallback: referencePlan.flatMap {
                                                $0.hasPerson ? PoseSkeleton.illustration(for: $0.poseStyle,
                                                                                        recipe: recipe) : nil
                                            },
                                            startingSetup: analysis?.shotSpec.source == .pose3D ? nil : startingSetup)
                                .frame(height: min(400, max(320, screen.size.height * 0.46)))

                            if analysis?.shotSpec.source != .pose3D {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Adjustable starting setup")
                                        .font(.system(size: 17, weight: .semibold))
                                    Text(startingSetup.distanceFromFace
                                         ? "Distance starts from face size and an assumed lens. Other values are adjustable suggestions, not camera measurements."
                                         : "These values are adjustable suggestions from the photo, not measurements of the original camera.")
                                        .font(PoserType.supporting)
                                        .foregroundStyle(Palette.secondaryText)
                                    setupSlider("Distance", value: $startingSetup.distanceMeters,
                                                range: 0.3...8, step: 0.1, unit: "m")
                                    setupSlider("Phone height", value: $startingSetup.heightMeters,
                                                range: 0.3...2.2, step: 0.1, unit: "m")
                                    setupSlider("Phone tilt", value: $startingSetup.tiltDegrees,
                                                range: -35...35, step: 5, unit: "°")
                                }
                                .padding(16)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
                            }

                            if let cue = analysis?.poseSkeleton?.shortCue {
                                Text(cue)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .multilineTextAlignment(.center)
                            }

                            if let referencePlan, referencePlan.hasPerson,
                               !referencePlan.poseCue.isEmpty {
                                Text(referencePlan.poseCue)
                                    .font(PoserType.supporting)
                                    .foregroundStyle(Palette.secondaryText)
                                    .multilineTextAlignment(.center)
                            }

                            if let detected = analysis?.poseSkeleton,
                               [PoseJoint.leftElbow, .leftWrist, .rightElbow, .rightWrist,
                                .leftKnee, .leftAnkle, .rightKnee, .rightAnkle]
                                .contains(where: { detected[$0] == nil }) {
                                Text("Faint limbs were not visible in the photo and are illustrative.")
                                    .font(PoserType.supporting)
                                    .foregroundStyle(Palette.secondaryText)
                                    .multilineTextAlignment(.center)
                            }

                            if let turn = shotGeometry.spec?.subjectTurnDegrees {
                                Text("Subject turns ≈\(abs(turn))° to their \(turn > 0 ? "right" : "left")")
                                    .font(PoserType.supporting)
                                    .foregroundStyle(Palette.secondaryText)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                        .padding(.top, PoserSpace.xLarge)
                        .padding(.bottom, PoserSpace.large)
                    }
                    .scrollIndicators(.hidden)

                    Button(action: onContinue) {
                        HStack(spacing: 9) {
                            Text("Open camera")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.white, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Closes the pose guide and shows the live camera")
                    .padding(.bottom, 22)
                }
                .padding(.horizontal, PoserSpace.large)
                .foregroundStyle(.white)
            }
        }
    }

    private func setupSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                             step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))))\(unit)")
                    .monospacedDigit()
            }
            .font(.system(size: 14, weight: .medium))
            Slider(value: value, in: range, step: step)
                .tint(.white)
        }
    }
}

private struct PoseDiagramView: View {
    let skeleton: PoseSkeleton
    let geometry: ShotGeometry
    let illustrativeFallback: PoseSkeleton?
    let startingSetup: ReferenceStartingSetup?

    var body: some View {
        GeometryReader { canvas in
            let layout = ShotDiagramLayout(size: canvas.size, geometry: geometry)
            let photographer = PoseSkeleton.photographer(
                cameraHeightMeters: geometry.cameraHeightMeters,
                phoneYInFigure: (layout.phonePoint.y - (layout.floor - layout.figureHeight)) / layout.figureHeight
            )
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 20, y: layout.floor))
                    path.addLine(to: CGPoint(x: canvas.size.width - 20, y: layout.floor))
                }
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7]))

                Path { path in
                    path.move(to: CGPoint(x: layout.photographerX + layout.figureWidth * 0.45, y: layout.floor - 14))
                    path.addLine(to: CGPoint(x: layout.subjectX - layout.figureWidth * 0.45, y: layout.floor - 14))
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                Path { path in
                    path.move(to: layout.phonePoint)
                    path.addLine(to: layout.aimPoint)
                }
                .stroke(.white.opacity(startingSetup == nil && geometry.spec?.pitchDegrees == nil ? 0.35 : 0.8),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                Path { path in
                    let x = max(16, layout.photographerX - layout.figureWidth * 0.55)
                    path.move(to: CGPoint(x: x, y: layout.floor))
                    path.addLine(to: CGPoint(x: x, y: layout.phonePoint.y))
                }
                .stroke(.white.opacity(startingSetup == nil && geometry.spec?.cameraHeightRatio == nil ? 0.35 : 0.8),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                BubblePoseFigure(target: photographer, completesMissingJoints: false, progress: 1)
                    .frame(width: layout.figureWidth, height: layout.figureHeight)
                    .position(x: layout.photographerX, y: layout.floor - layout.figureHeight / 2)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-Double(self.geometry.tiltDegrees)))
                    .position(layout.phonePoint)

                AnimatedPoseFigure(skeleton: skeleton, illustrativeFallback: illustrativeFallback)
                    .frame(width: layout.figureWidth, height: layout.figureHeight)
                    .position(x: layout.subjectX, y: layout.floor - layout.figureHeight / 2)

                if let turn = geometry.spec?.subjectTurnDegrees {
                    Image(systemName: turn > 0 ? "arrow.clockwise" : "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .position(x: layout.subjectX + (turn > 0 ? 1 : -1) * layout.figureWidth * 0.59,
                                  y: layout.floor - layout.figureHeight * 0.53)
                }

                guideLabel(startingSetup.map { "Start ≈\($0.heightMeters.formatted(.number.precision(.fractionLength(1)))) m high" }
                           ?? self.geometry.adjustmentLabel, width: min(116, canvas.size.width * 0.31))
                    .position(x: layout.photographerX, y: layout.floor - layout.figureHeight - 23)
                guideLabel(startingSetup.map { "Start tilt \(Int($0.tiltDegrees))°" }
                           ?? self.geometry.angleLabel, width: min(116, canvas.size.width * 0.31))
                    .position(x: layout.subjectX, y: layout.floor - layout.figureHeight - 23)
                guideLabel(startingSetup.map { "Start \(ShotSpec.formatDistance($0.distanceMeters)) away" }
                           ?? self.geometry.distanceLabel, width: min(210, canvas.size.width * 0.58))
                    .position(x: canvas.size.width * 0.5, y: canvas.size.height - 25)
                Text("PHOTOGRAPHER")
                    .position(x: layout.photographerX, y: layout.floor + 22)
                Text("SUBJECT")
                    .position(x: layout.subjectX, y: layout.floor + 22)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(startingSetup.map {
            "Adjustable setup: phone \($0.heightMeters.formatted(.number.precision(.fractionLength(1)))) meters high, " +
            "distance \($0.distanceMeters.formatted(.number.precision(.fractionLength(1)))) meters, " +
            "tilt \(Int($0.tiltDegrees)) degrees"
        } ?? "Animated setup: photographer at \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
    }

    private func guideLabel(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .frame(width: width)
            .shadow(color: .black, radius: 5)
    }
}

private extension PoseSkeleton {
    static func illustration(for style: GeminiReferencePlan.PoseStyle,
                             recipe: ShotRecipe) -> PoseSkeleton {
        var points = example(for: recipe).points
        switch style {
        case .walking:
            points[.leftWrist] = CGPoint(x: 0.29, y: 0.44)
            points[.rightWrist] = CGPoint(x: 0.70, y: 0.53)
            points[.leftKnee] = CGPoint(x: 0.34, y: 0.72)
            points[.leftAnkle] = CGPoint(x: 0.25, y: 0.94)
            points[.rightKnee] = CGPoint(x: 0.65, y: 0.75)
            points[.rightAnkle] = CGPoint(x: 0.72, y: 0.94)
        case .seated:
            points[.leftHip] = CGPoint(x: 0.42, y: 0.58)
            points[.rightHip] = CGPoint(x: 0.58, y: 0.58)
            points[.leftKnee] = CGPoint(x: 0.28, y: 0.68)
            points[.rightKnee] = CGPoint(x: 0.74, y: 0.68)
            points[.leftAnkle] = CGPoint(x: 0.28, y: 0.92)
            points[.rightAnkle] = CGPoint(x: 0.75, y: 0.92)
            points[.leftWrist] = CGPoint(x: 0.38, y: 0.62)
            points[.rightWrist] = CGPoint(x: 0.64, y: 0.62)
        case .leaning:
            points[.nose] = CGPoint(x: 0.58, y: 0.12)
            points[.neck] = CGPoint(x: 0.56, y: 0.23)
            points[.leftShoulder] = CGPoint(x: 0.45, y: 0.29)
            points[.rightShoulder] = CGPoint(x: 0.69, y: 0.27)
            points[.leftElbow] = CGPoint(x: 0.38, y: 0.42)
            points[.rightElbow] = CGPoint(x: 0.73, y: 0.42)
        case .standing, .unknown:
            break
        }
        return PoseSkeleton(points: points)
    }

    static func photographer(cameraHeightMeters: Double, phoneYInFigure: CGFloat) -> PoseSkeleton {
        let crouch = min(1, max(0, CGFloat((1.25 - cameraHeightMeters) / 0.6)))
        let upright = photographer(crouched: false)
        let low = photographer(crouched: true)
        var points: [PoseJoint: CGPoint] = [:]
        for joint in PoseJoint.allCases {
            guard let a = upright[joint], let b = low[joint] else { continue }
            points[joint] = CGPoint(x: a.x + (b.x - a.x) * crouch,
                                    y: a.y + (b.y - a.y) * crouch)
        }

        // BubblePoseFigure compresses vertical coordinates into the drawing.
        // Invert that transform so both hands meet the height marker at the phone.
        let wristY = min(0.97, max(0.02, 0.95 + (phoneYInFigure - 0.95) / 0.9))
        points[.leftWrist] = CGPoint(x: 0.78, y: wristY - 0.01)
        points[.rightWrist] = CGPoint(x: 0.78, y: wristY + 0.01)
        if let shoulder = points[.leftShoulder] {
            points[.leftElbow] = CGPoint(x: 0.59, y: shoulder.y + (wristY - shoulder.y) * 0.55)
        }
        if let shoulder = points[.rightShoulder] {
            points[.rightElbow] = CGPoint(x: 0.67, y: shoulder.y + (wristY - shoulder.y) * 0.55)
        }
        return PoseSkeleton(points: points)
    }

    static func photographer(crouched: Bool) -> PoseSkeleton {
        if crouched {
            return PoseSkeleton(points: [
                .nose: CGPoint(x: 0.41, y: 0.31), .neck: CGPoint(x: 0.42, y: 0.42),
                .leftShoulder: CGPoint(x: 0.35, y: 0.47), .rightShoulder: CGPoint(x: 0.55, y: 0.47),
                .leftElbow: CGPoint(x: 0.53, y: 0.54), .leftWrist: CGPoint(x: 0.78, y: 0.59),
                .rightElbow: CGPoint(x: 0.66, y: 0.55), .rightWrist: CGPoint(x: 0.78, y: 0.62),
                .leftHip: CGPoint(x: 0.28, y: 0.66), .rightHip: CGPoint(x: 0.40, y: 0.66),
                .leftKnee: CGPoint(x: 0.43, y: 0.81), .rightKnee: CGPoint(x: 0.66, y: 0.78),
                .leftAnkle: CGPoint(x: 0.18, y: 0.96), .rightAnkle: CGPoint(x: 0.53, y: 0.97)
            ])
        }
        return PoseSkeleton(points: [
            .nose: CGPoint(x: 0.43, y: 0.13), .neck: CGPoint(x: 0.44, y: 0.25),
            .leftShoulder: CGPoint(x: 0.35, y: 0.30), .rightShoulder: CGPoint(x: 0.55, y: 0.30),
            .leftElbow: CGPoint(x: 0.53, y: 0.38), .leftWrist: CGPoint(x: 0.78, y: 0.43),
            .rightElbow: CGPoint(x: 0.66, y: 0.40), .rightWrist: CGPoint(x: 0.78, y: 0.46),
            .leftHip: CGPoint(x: 0.37, y: 0.56), .rightHip: CGPoint(x: 0.54, y: 0.56),
            .leftKnee: CGPoint(x: 0.30, y: 0.76), .rightKnee: CGPoint(x: 0.60, y: 0.76),
            .leftAnkle: CGPoint(x: 0.21, y: 0.97), .rightAnkle: CGPoint(x: 0.65, y: 0.97)
        ])
    }
}

struct MiniPoseGuide: View {
    let skeleton: PoseSkeleton
    let geometry: ShotGeometry

    private var distanceWidth: CGFloat {
        9 + 18 * ShotDiagramLayout.distanceFraction(geometry.distanceMeters)
    }

    private var phoneOffset: CGFloat {
        guard geometry.spec?.cameraHeightRatio != nil else { return 0 }
        let subjectHeight = max(1.2, geometry.spec?.subjectHeightMeters ?? ShotSpecEstimator.defaultSubjectHeight)
        return CGFloat(0.6 - geometry.cameraHeightMeters / subjectHeight) * 35
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 21, weight: .ultraLight))
                .rotationEffect(.degrees(-Double(geometry.tiltDegrees)))
                .offset(y: phoneOffset)
            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(width: distanceWidth, height: 1)
            AnimatedPoseFigure(skeleton: skeleton)
                .frame(width: 48, height: 82)
        }
            .frame(width: 128, height: 110)
            .poserGlass()
            .accessibilityLabel("Animated setup: \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
    }
}

private struct AnimatedPoseFigure: View {
    let skeleton: PoseSkeleton
    var illustrativeFallback: PoseSkeleton? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        BubblePoseFigure(target: skeleton, illustrativeFallback: illustrativeFallback, progress: progress)
            .onAppear {
                if reduceMotion {
                    progress = 1
                } else {
                    progress = 0
                    withAnimation(.easeOut(duration: 0.85)) { progress = 1 }
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { progress = 1 }
            }
    }
}

struct BubblePoseFigure: View, Animatable {
    let target: PoseSkeleton
    var illustrativeFallback: PoseSkeleton? = nil
    var completesMissingJoints = true
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let neutral = PoseSkeleton.example(for: ShotRecipe.presets[1])
            let completeTarget = completesMissingJoints
                ? target.displayingMissingJoints(fallback: illustrativeFallback) : target
            func point(_ joint: PoseJoint) -> CGPoint? {
                guard let end = completeTarget[joint] else { return nil }
                let rest = neutral[joint] ?? end
                let start = CGPoint(x: end.x + (rest.x - end.x) * 0.22,
                                    y: end.y + (rest.y - end.y) * 0.22)
                let x = start.x + (end.x - start.x) * progress
                let y = start.y + (end.y - start.y) * progress
                let drawingY = (0.95 + (y - 0.95) * 0.9) * size.height
                // Keep the entire round foot inside the canvas at every figure size.
                let footInset = max(4, size.width * 0.145) * 0.56 + 1
                let isAnkle = joint == .leftAnkle || joint == .rightAnkle
                return CGPoint(x: (0.5 + (x - 0.5) * 1.3) * size.width,
                               y: isAnkle ? min(drawingY, size.height - footInset) : drawingY)
            }
            let white = GraphicsContext.Shading.color(.white)
            func limb(_ start: PoseJoint, _ bend: PoseJoint, _ end: PoseJoint, width: CGFloat) {
                guard let a = point(start), let b = point(bend), let c = point(end) else { return }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: c)
                let observed = target[start] != nil && target[bend] != nil && target[end] != nil
                context.stroke(path, with: .color(.white.opacity(observed ? 1 : 0.35)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

            // Sign-style silhouettes: generous, continuous capsules with round joints.
            let thickness = max(4, size.width * 0.145)
            limb(.leftHip, .leftKnee, .leftAnkle, width: thickness * 1.12)
            limb(.rightHip, .rightKnee, .rightAnkle, width: thickness * 1.12)
            if let ls = point(.leftShoulder), let rs = point(.rightShoulder),
               let lh = point(.leftHip), let rh = point(.rightHip) {
                let shoulderCenter = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
                let shoulderCurve = size.height * 0.025
                var torso = Path()
                torso.move(to: CGPoint(x: ls.x, y: ls.y + shoulderCurve))
                torso.addQuadCurve(to: shoulderCenter,
                                   control: CGPoint(x: ls.x, y: ls.y - shoulderCurve * 0.3))
                torso.addQuadCurve(to: CGPoint(x: rs.x, y: rs.y + shoulderCurve),
                                   control: CGPoint(x: rs.x, y: rs.y - shoulderCurve * 0.3))
                torso.addLine(to: rh)
                torso.addQuadCurve(to: lh,
                                   control: CGPoint(x: (lh.x + rh.x) / 2, y: max(lh.y, rh.y) + shoulderCurve * 0.3))
                torso.closeSubpath()
                let observedTorso = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
                    .allSatisfy { target[$0] != nil }
                // A rounded contour softens both the shoulders and the hip corners.
                // Draw in one layer so illustrative bodies do not accumulate opacity.
                context.drawLayer { body in
                    body.opacity = observedTorso ? 1 : 0.35
                    body.fill(torso, with: white)
                    body.stroke(torso, with: white,
                                style: StrokeStyle(lineWidth: thickness * 0.65,
                                                   lineCap: .round, lineJoin: .round))
                }
            }
            limb(.leftShoulder, .leftElbow, .leftWrist, width: thickness)
            limb(.rightShoulder, .rightElbow, .rightWrist, width: thickness)

            if let head = point(.nose) {
                let radius = max(6, size.width * 0.145)
                let center = head
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: target[.nose] == nil ? .color(.white.opacity(0.35)) : white)
            }
        }
    }
}
