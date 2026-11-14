import SwiftUI

struct PoseTutorialView: View {
    let referenceImage: UIImage?
    let analysis: PhotoAnalysis?
    let recipe: ShotRecipe
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var skeleton: PoseSkeleton {
        analysis?.poseSkeleton ?? .example(for: recipe)
    }

    private var distanceLabel: String {
        switch recipe.id {
        case "street": "ABOUT 2.5 M"
        case "nature": "ABOUT 3 M"
        case "cafe": "ACROSS THE TABLE"
        default: "STEP BACK"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                Spacer()
                Text("Pose guide")
                    .font(PoserType.wordmark)
                Spacer()
                if let referenceImage {
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.top, 12)

            Text("Match the pose")
                .font(.system(size: 31, weight: .bold))
                .padding(.top, 28)
            Text(analysis?.poseSkeleton == nil ? "Example stance for this shot" : "Built from the person in your reference")
                .font(PoserType.supporting)
                .foregroundStyle(Palette.secondaryText)
                .padding(.top, 6)

            PoseDiagramView(skeleton: skeleton, distanceLabel: distanceLabel)
                .frame(height: 310)
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 17) {
                guideLine(symbol: "figure.stand", title: "Subject", detail: recipe.pose)
                Rectangle().fill(Palette.border).frame(height: 1)
                guideLine(symbol: "iphone", title: "Camera", detail: recipe.camera)
            }
            .padding(.top, 25)

            Spacer(minLength: 20)
            Button {
                dismiss()
                onContinue()
            } label: {
                Text("Open camera")
                    .font(PoserType.action)
                    .foregroundStyle(Palette.background)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Palette.primaryText, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 22)
        }
        .padding(.horizontal, PoserSpace.large)
        .foregroundStyle(Palette.primaryText)
        .background(Palette.background.ignoresSafeArea())
    }

    private func guideLine(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PoseDiagramView: View {
    let skeleton: PoseSkeleton
    let distanceLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var posed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: PoserRadius.image)
                    .fill(Palette.surface)
                Path { path in
                    let y = geometry.size.height - 42
                    path.move(to: CGPoint(x: 24, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width - 24, y: y))
                }
                .stroke(Palette.tertiaryText, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))

                VStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 28, weight: .ultraLight))
                    Text("CAMERA")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1)
                }
                .foregroundStyle(Palette.secondaryText)
                .position(x: geometry.size.width * 0.17, y: geometry.size.height * 0.57)

                PoseFigureShape(target: skeleton, progress: posed ? 1 : 0)
                    .stroke(Palette.primaryText, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: min(170, geometry.size.width * 0.48), height: 235)
                    .position(x: geometry.size.width * 0.67, y: geometry.size.height * 0.45)

                Text(distanceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.secondaryText)
                    .position(x: geometry.size.width * 0.49, y: geometry.size.height - 23)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated stick figure showing the reference pose and camera distance")
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
