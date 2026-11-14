import SwiftUI

struct PoseTutorialView: View {
    let analysis: PhotoAnalysis?
    let recipe: ShotRecipe
    let onContinue: () -> Void
    let onClose: () -> Void

    private var skeleton: PoseSkeleton {
        analysis?.poseSkeleton ?? .example(for: recipe)
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Button { onClose() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.42), in: Circle())
                        }
                        Spacer()
                        Text("poser")
                            .font(PoserType.wordmark)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.top, 12)

                    Spacer(minLength: 30)
                    Text(analysis?.poseSkeleton == nil ? "EXAMPLE SETUP" : "MATCH THIS POSE")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .tracking(2)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                    PoseDiagramView(skeleton: skeleton, geometry: analysis?.geometry ?? ShotGeometryEstimator.fallback(for: recipe))
                        .frame(height: min(430, screen.size.height * 0.52))
                        .padding(.top, 14)
                    Text(analysis?.poseSkeleton?.shortCue ?? "Use the reference to adjust your pose")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    if let turn = analysis?.geometry.spec?.subjectTurnDegrees {
                        Text("Subject turns ≈\(abs(turn))° to their \(turn > 0 ? "right" : "left")")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 24)

                    Button(action: onContinue) {
                        HStack(spacing: 9) {
                            Text("Open camera")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var posed = false

    var body: some View {
        GeometryReader { canvas in
            let floor = canvas.size.height * 0.79
            let photographerX = canvas.size.width * 0.23
            let subjectX = canvas.size.width * 0.78
            let crouched = self.geometry.cameraHeightMeters < 1.1
            let phonePoint = CGPoint(x: photographerX + 43, y: floor - (crouched ? 88 : 130))
            let subjectPoint = CGPoint(x: subjectX - 25, y: floor - 146)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 20, y: floor))
                    path.addLine(to: CGPoint(x: canvas.size.width - 20, y: floor))
                }
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7]))

                Path { path in
                    path.move(to: CGPoint(x: photographerX + 48, y: floor - 14))
                    path.addLine(to: CGPoint(x: subjectX - 48, y: floor - 14))
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                Path { path in
                    path.move(to: phonePoint)
                    path.addLine(to: subjectPoint)
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                Path { path in
                    path.move(to: CGPoint(x: photographerX + 56, y: floor - (crouched ? 145 : 194)))
                    path.addLine(to: CGPoint(x: photographerX + 56, y: phonePoint.y))
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

                BubblePoseFigure(target: .photographer(crouched: crouched), progress: 1)
                    .frame(width: 128, height: 206)
                    .position(x: photographerX, y: floor - 104)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-Double(self.geometry.tiltDegrees)))
                    .position(phonePoint)

                BubblePoseFigure(target: skeleton, progress: posed ? 1 : 0)
                    .frame(width: 128, height: 206)
                    .position(x: subjectX, y: floor - 104)

                guideLabel(self.geometry.adjustmentLabel)
                    .position(x: photographerX, y: floor - 230)
                guideLabel(self.geometry.angleLabel)
                    .position(x: subjectX, y: floor - 230)
                guideLabel(self.geometry.distanceLabel)
                    .position(x: canvas.size.width * 0.5, y: canvas.size.height - 25)
                Text("PHOTOGRAPHER")
                    .position(x: photographerX, y: floor + 22)
                Text("SUBJECT")
                    .position(x: subjectX, y: floor + 22)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated setup: photographer at \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
        .onAppear {
            if reduceMotion {
                posed = true
            } else {
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                    posed = true
                }
            }
        }
    }

    private func guideLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .frame(width: 132)
            .shadow(color: .black, radius: 5)
    }
}

private extension PoseSkeleton {
    static func photographer(crouched: Bool) -> PoseSkeleton {
        if crouched {
            return PoseSkeleton(points: [
                .nose: CGPoint(x: 0.41, y: 0.31), .neck: CGPoint(x: 0.42, y: 0.42),
                .leftShoulder: CGPoint(x: 0.31, y: 0.47), .rightShoulder: CGPoint(x: 0.54, y: 0.47),
                .leftElbow: CGPoint(x: 0.55, y: 0.51), .leftWrist: CGPoint(x: 0.73, y: 0.60),
                .rightElbow: CGPoint(x: 0.51, y: 0.64), .rightWrist: CGPoint(x: 0.72, y: 0.62),
                .leftHip: CGPoint(x: 0.43, y: 0.67), .rightHip: CGPoint(x: 0.57, y: 0.67),
                .leftKnee: CGPoint(x: 0.28, y: 0.78), .rightKnee: CGPoint(x: 0.72, y: 0.81),
                .leftAnkle: CGPoint(x: 0.16, y: 0.96), .rightAnkle: CGPoint(x: 0.63, y: 0.97)
            ])
        }
        return PoseSkeleton(points: [
            .nose: CGPoint(x: 0.41, y: 0.13), .neck: CGPoint(x: 0.42, y: 0.25),
            .leftShoulder: CGPoint(x: 0.31, y: 0.30), .rightShoulder: CGPoint(x: 0.54, y: 0.30),
            .leftElbow: CGPoint(x: 0.57, y: 0.36), .leftWrist: CGPoint(x: 0.72, y: 0.40),
            .rightElbow: CGPoint(x: 0.55, y: 0.46), .rightWrist: CGPoint(x: 0.72, y: 0.45),
            .leftHip: CGPoint(x: 0.37, y: 0.56), .rightHip: CGPoint(x: 0.54, y: 0.56),
            .leftKnee: CGPoint(x: 0.30, y: 0.76), .rightKnee: CGPoint(x: 0.60, y: 0.76),
            .leftAnkle: CGPoint(x: 0.21, y: 0.97), .rightAnkle: CGPoint(x: 0.65, y: 0.97)
        ])
    }
}

struct MiniPoseGuide: View {
    let skeleton: PoseSkeleton
    let geometry: ShotGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var posed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 21, weight: .ultraLight))
                .rotationEffect(.degrees(-Double(geometry.tiltDegrees)))
            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(width: 17, height: 1)
            BubblePoseFigure(target: skeleton, progress: posed ? 1 : 0)
                .frame(width: 48, height: 82)
        }
            .frame(width: 128, height: 110)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: PoserRadius.control))
            .accessibilityLabel("Animated setup: \(geometry.heightLabel), \(geometry.distanceLabel), \(geometry.angleLabel)")
            .onAppear {
                if reduceMotion {
                    posed = true
                } else {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        posed = true
                    }
                }
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
            func point(_ joint: PoseJoint) -> CGPoint? {
                guard let end = target[joint] else { return nil }
                let start = neutral[joint] ?? end
                return CGPoint(x: (start.x + (end.x - start.x) * progress) * size.width,
                               y: (start.y + (end.y - start.y) * progress) * size.height)
            }
            let white = GraphicsContext.Shading.color(.white)
            func limb(_ start: PoseJoint, _ bend: PoseJoint, _ end: PoseJoint, width: CGFloat) {
                guard let a = point(start), let b = point(bend), let c = point(end) else { return }
                var path = Path()
                path.move(to: a)
                path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                path.addQuadCurve(to: c, control: CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2))
                context.stroke(path, with: white,
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

            let thickness = max(5, size.width * 0.067)
            limb(.leftHip, .leftKnee, .leftAnkle, width: thickness * 1.08)
            limb(.rightHip, .rightKnee, .rightAnkle, width: thickness * 1.08)
            if let ls = point(.leftShoulder), let rs = point(.rightShoulder),
               let lh = point(.leftHip), let rh = point(.rightHip) {
                var torso = Path()
                let inset = size.width * 0.025
                torso.move(to: CGPoint(x: ls.x + inset, y: ls.y))
                torso.addQuadCurve(to: CGPoint(x: rs.x - inset, y: rs.y),
                                   control: CGPoint(x: (ls.x + rs.x) / 2, y: min(ls.y, rs.y) - size.height * 0.015))
                torso.addQuadCurve(to: rh, control: CGPoint(x: rs.x - inset, y: (rs.y + rh.y) / 2))
                torso.addQuadCurve(to: lh, control: CGPoint(x: (lh.x + rh.x) / 2, y: max(lh.y, rh.y)))
                torso.addQuadCurve(to: CGPoint(x: ls.x + inset, y: ls.y),
                                   control: CGPoint(x: ls.x + inset, y: (ls.y + lh.y) / 2))
                torso.closeSubpath()
                context.fill(torso, with: white)
            }
            limb(.leftShoulder, .leftElbow, .leftWrist, width: thickness)
            limb(.rightShoulder, .rightElbow, .rightWrist, width: thickness)

            if let head = point(.nose) {
                let radius = max(6, size.width * 0.105)
                if let neck = point(.neck) {
                    var neckPath = Path()
                    neckPath.move(to: CGPoint(x: head.x, y: head.y + radius * 0.7))
                    neckPath.addLine(to: neck)
                    context.stroke(neckPath, with: white,
                                   style: StrokeStyle(lineWidth: thickness * 0.8, lineCap: .round))
                }
                context.fill(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                                    width: radius * 2, height: radius * 2)), with: white)
            }
        }
    }
}
