import SwiftUI

struct PoseTutorialView: View {
    let analysis: PhotoAnalysis?
    let recipe: ShotRecipe
    let onContinue: () -> Void
    let onClose: () -> Void

    private var skeleton: PoseSkeleton {
        analysis?.poseSkeleton ?? .example(for: recipe)
    }

    private var shotGeometry: ShotGeometry {
        analysis?.geometry ?? ShotGeometryEstimator.fallback(for: recipe)
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
                                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: PoserRadius.control))
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
                            Text(analysis?.poseSkeleton == nil ? "EXAMPLE SETUP" : "MATCH THIS POSE")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .tracking(2)
                                .multilineTextAlignment(.center)

                            PoseDiagramView(skeleton: skeleton, geometry: shotGeometry)
                                .frame(height: min(400, max(320, screen.size.height * 0.46)))

                            if let cue = analysis?.poseSkeleton?.shortCue {
                                Text(cue)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
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
}

private struct PoseDiagramView: View {
    let skeleton: PoseSkeleton
    let geometry: ShotGeometry

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
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                Path { path in
                    let x = max(16, layout.photographerX - layout.figureWidth * 0.55)
                    path.move(to: CGPoint(x: x, y: layout.floor))
                    path.addLine(to: CGPoint(x: x, y: layout.phonePoint.y))
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                BubblePoseFigure(target: photographer, progress: 1)
                    .frame(width: layout.figureWidth, height: layout.figureHeight)
                    .position(x: layout.photographerX, y: layout.floor - layout.figureHeight / 2)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-Double(self.geometry.tiltDegrees)))
                    .position(layout.phonePoint)

                AnimatedPoseFigure(skeleton: skeleton)
                    .frame(width: layout.figureWidth, height: layout.figureHeight)
                    .position(x: layout.subjectX, y: layout.floor - layout.figureHeight / 2)

                if let turn = geometry.spec?.subjectTurnDegrees {
                    Image(systemName: turn > 0 ? "arrow.clockwise" : "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .position(x: layout.subjectX + (turn > 0 ? 1 : -1) * layout.figureWidth * 0.59,
                                  y: layout.floor - layout.figureHeight * 0.53)
                }

                guideLabel(self.geometry.adjustmentLabel, width: min(116, canvas.size.width * 0.31))
                    .position(x: layout.photographerX, y: layout.floor - layout.figureHeight - 23)
                guideLabel(self.geometry.angleLabel, width: min(116, canvas.size.width * 0.31))
                    .position(x: layout.subjectX, y: layout.floor - layout.figureHeight - 23)
                guideLabel(self.geometry.distanceLabel, width: min(210, canvas.size.width * 0.58))
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
        .accessibilityLabel("Animated setup: photographer at \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
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
                .leftHip: CGPoint(x: 0.43, y: 0.67), .rightHip: CGPoint(x: 0.57, y: 0.67),
                .leftKnee: CGPoint(x: 0.28, y: 0.78), .rightKnee: CGPoint(x: 0.72, y: 0.81),
                .leftAnkle: CGPoint(x: 0.16, y: 0.96), .rightAnkle: CGPoint(x: 0.63, y: 0.97)
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
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: PoserRadius.control))
            .accessibilityLabel("Animated setup: \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
    }
}

private struct AnimatedPoseFigure: View {
    let skeleton: PoseSkeleton
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        BubblePoseFigure(target: skeleton, progress: progress)
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
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let neutral = PoseSkeleton.example(for: ShotRecipe.presets[1])
            let completeTarget = target.displayingMissingJoints()
            let hipY = ((completeTarget[.leftHip]?.y ?? 0.55) + (completeTarget[.rightHip]?.y ?? 0.55)) / 2
            let ankleY = ((completeTarget[.leftAnkle]?.y ?? 0.94) + (completeTarget[.rightAnkle]?.y ?? 0.94)) / 2
            let legOffset = min(0.08, max(0, (ankleY - hipY) * 0.2))
            func point(_ joint: PoseJoint) -> CGPoint? {
                guard let end = completeTarget[joint] else { return nil }
                let rest = neutral[joint] ?? end
                let start = CGPoint(x: end.x + (rest.x - end.x) * 0.22,
                                    y: end.y + (rest.y - end.y) * 0.22)
                let x = start.x + (end.x - start.x) * progress
                let y = start.y + (end.y - start.y) * progress
                let bodyOffset: CGFloat
                switch joint {
                case .leftHip, .rightHip: bodyOffset = legOffset
                case .leftKnee, .rightKnee: bodyOffset = legOffset / 2
                default: bodyOffset = 0
                }
                return CGPoint(x: (0.5 + (x - 0.5) * 1.3) * size.width,
                               y: (0.95 + (y + bodyOffset - 0.95) * 0.9) * size.height)
            }
            let white = GraphicsContext.Shading.color(.white)
            func limb(_ start: PoseJoint, _ bend: PoseJoint, _ end: PoseJoint, width: CGFloat) {
                guard let a = point(start), let b = point(bend), let c = point(end) else { return }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: c)
                context.stroke(path, with: white,
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

            let thickness = max(3, size.width * 0.072)
            limb(.leftHip, .leftKnee, .leftAnkle, width: thickness)
            limb(.rightHip, .rightKnee, .rightAnkle, width: thickness)
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
                context.fill(torso, with: white)
            }
            limb(.leftShoulder, .leftElbow, .leftWrist, width: thickness)
            limb(.rightShoulder, .rightElbow, .rightWrist, width: thickness)

            if let head = point(.nose) {
                let radius = max(4.8, size.width * 0.09)
                let neck = point(.neck) ?? head
                let center = CGPoint(x: (head.x + neck.x) / 2, y: (head.y + neck.y) / 2)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2)), with: white)
            }
        }
    }
}
