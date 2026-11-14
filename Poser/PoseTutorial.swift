import SwiftUI

struct PoseTutorialView: View {
    let referenceImage: UIImage?
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
                if let referenceImage {
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: screen.size.width, height: screen.size.height)
                        .clipped()
                        .ignoresSafeArea()
                } else {
                    Palette.background.ignoresSafeArea()
                }
                LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.35), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

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
                    Text("MATCH THIS SHOT")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(2)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                    PoseDiagramView(skeleton: skeleton, geometry: analysis?.geometry ?? ShotGeometryEstimator.fallback(for: recipe))
                        .frame(height: min(380, screen.size.height * 0.48))
                        .padding(.top, 14)
                    Spacer(minLength: 24)

                    Button(action: onContinue) {
                        HStack(spacing: 9) {
                            Text("Open camera")
                            Image(systemName: "arrow.right")
                        }
                        .font(PoserType.action)
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
        .background(Palette.background.ignoresSafeArea())
    }
}

private struct PoseDiagramView: View {
    let skeleton: PoseSkeleton
    let geometry: ShotGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var posed = false

    var body: some View {
        GeometryReader { canvas in
            let floor = canvas.size.height * 0.8
            let photographerX = canvas.size.width * 0.23
            let subjectX = canvas.size.width * 0.78
            let crouched = self.geometry.cameraHeightMeters < 1.1
            let phonePoint = CGPoint(x: photographerX + 34, y: floor - (crouched ? 72 : 107))
            let subjectPoint = CGPoint(x: subjectX - 20, y: floor - 120)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 20, y: floor))
                    path.addLine(to: CGPoint(x: canvas.size.width - 20, y: floor))
                }
                .stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))

                Path { path in
                    path.move(to: CGPoint(x: photographerX + 43, y: floor - 12))
                    path.addLine(to: CGPoint(x: subjectX - 40, y: floor - 12))
                }
                .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))

                Path { path in
                    path.move(to: phonePoint)
                    path.addLine(to: subjectPoint)
                }
                .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))

                Path { path in
                    path.move(to: CGPoint(x: photographerX + 48, y: floor - (crouched ? 116 : 158)))
                    path.addLine(to: CGPoint(x: photographerX + 48, y: phonePoint.y))
                }
                .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))

                PhotographerFigureShape(crouched: crouched)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 112, height: 177)
                    .position(x: photographerX, y: floor - 90)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-Double(self.geometry.tiltDegrees)))
                    .position(phonePoint)

                PoseFigureShape(target: skeleton, progress: posed ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 112, height: 177)
                    .position(x: subjectX, y: floor - 90)

                Text(self.geometry.adjustmentLabel)
                    .position(x: photographerX + 24, y: 36)
                Text(self.geometry.angleLabel)
                    .position(x: canvas.size.width * 0.61, y: 78)
                Text(self.geometry.distanceLabel)
                    .position(x: canvas.size.width * 0.5, y: canvas.size.height - 27)
                Text("PHOTOGRAPHER")
                    .position(x: photographerX, y: floor + 20)
                Text("SUBJECT")
                    .position(x: subjectX, y: floor + 20)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.78))
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
}

private struct PhotographerFigureShape: Shape {
    let crouched: Bool

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        let headY: CGFloat = crouched ? 0.25 : 0.06
        path.addEllipse(in: CGRect(x: p(0.31, headY).x, y: p(0, headY).y,
                                width: rect.width * 0.24, height: rect.height * 0.15))
        if crouched {
            path.move(to: p(0.43, 0.40))
            path.addLine(to: p(0.52, 0.68))
            path.move(to: p(0.45, 0.47))
            path.addLine(to: p(0.58, 0.50))
            path.addLine(to: p(0.69, 0.60))
            path.move(to: p(0.45, 0.47))
            path.addLine(to: p(0.53, 0.62))
            path.addLine(to: p(0.69, 0.62))
            path.move(to: p(0.52, 0.68))
            path.addLine(to: p(0.29, 0.75))
            path.addLine(to: p(0.19, 0.98))
            path.move(to: p(0.52, 0.68))
            path.addLine(to: p(0.69, 0.83))
            path.addLine(to: p(0.62, 0.98))
        } else {
            path.move(to: p(0.43, 0.21))
            path.addLine(to: p(0.43, 0.55))
            path.move(to: p(0.43, 0.28))
            path.addLine(to: p(0.55, 0.34))
            path.addLine(to: p(0.69, 0.39))
            path.move(to: p(0.43, 0.28))
            path.addLine(to: p(0.49, 0.43))
            path.addLine(to: p(0.69, 0.41))
            path.move(to: p(0.43, 0.55))
            path.addLine(to: p(0.29, 0.77))
            path.addLine(to: p(0.23, 0.98))
            path.move(to: p(0.43, 0.55))
            path.addLine(to: p(0.57, 0.77))
            path.addLine(to: p(0.64, 0.98))
        }
        return path
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
            PoseFigureShape(target: skeleton, progress: posed ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
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

private struct PoseFigureShape: Shape {
    let target: PoseSkeleton
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let neutral = PoseSkeleton.example(for: ShotRecipe.presets[1])
        func point(_ joint: PoseJoint) -> CGPoint {
            let start = neutral[joint] ?? CGPoint(x: 0.5, y: 0.5)
            let end = target[joint] ?? start
            let x = start.x + (end.x - start.x) * progress
            let y = start.y + (end.y - start.y) * progress
            return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        let head = point(.nose)
        path.addEllipse(in: CGRect(x: head.x - 12, y: head.y - 12, width: 24, height: 24))
        path.move(to: CGPoint(x: head.x, y: head.y + 12))
        path.addLine(to: point(.neck))
        let segments: [(PoseJoint, PoseJoint)] = [
            (.neck, .leftShoulder), (.neck, .rightShoulder),
            (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
            (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
            (.leftHip, .rightHip),
            (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
        ]
        for (from, to) in segments {
            path.move(to: point(from))
            path.addLine(to: point(to))
        }
        return path
    }
}
