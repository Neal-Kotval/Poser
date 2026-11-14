import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UIKit
import Vision
import simd

enum LensModel {
    static let phoneMainEquivalentMM = 26.0
    private static let fullFrameDiagonalMM = 43.27

    /// The smallest 3:4 frame that contains `size`. Phone photos are crops of a 3:4 sensor,
    /// so a 9:16 image keeps the long side and a square image keeps the short side.
    static func captureFrame(containing size: CGSize) -> CGSize {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard long > 0 else { return size }
        let frameLong = short / long < 0.75 ? long : short / 0.75
        let frameShort = frameLong * 0.75
        return size.width >= size.height
            ? CGSize(width: frameLong, height: frameShort)
            : CGSize(width: frameShort, height: frameLong)
    }

    static func focalLengthPixels(imageSize: CGSize, equivalentMM: Double) -> Double {
        let frame = captureFrame(containing: imageSize)
        return Double(hypot(frame.width, frame.height)) * equivalentMM / fullFrameDiagonalMM
    }

    static func equivalentFocalLength(imageData: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let millimeters = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
              millimeters > 0 else { return nil }
        return millimeters
    }

    static func intrinsicsData(width: Int, height: Int, focalPixels: Double) -> Data {
        var matrix = matrix_float3x3(columns: (
            SIMD3<Float>(Float(focalPixels), 0, 0),
            SIMD3<Float>(0, Float(focalPixels), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))
        return Data(bytes: &matrix, count: MemoryLayout<matrix_float3x3>.size)
    }

    static func focalPixels(fromIntrinsics data: Data) -> Double? {
        guard data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        return Double(matrix.columns.0.x)
    }
}

enum FaceDistanceEstimator {
    /// A rough adult face width. This is a starting distance, not camera metadata.
    static let nominalFaceWidthMeters = 0.16

    static func distance(focalPixels: Double, imageWidth: Double,
                         faceWidthFraction: CGFloat) -> Double? {
        guard focalPixels.isFinite, focalPixels > 0, imageWidth.isFinite, imageWidth > 0,
              faceWidthFraction.isFinite, (0.08...0.7).contains(faceWidthFraction) else { return nil }
        let meters = focalPixels * nominalFaceWidthMeters / (imageWidth * Double(faceWidthFraction))
        return (0.25...5).contains(meters) ? meters : nil
    }
}

struct CameraPlacement: Equatable {
    let heightRatio: Double
    /// In Vision's body-frame units, which assume `bodyHeight` meters tall.
    let horizontalDistance: Double
    let subjectYawDegrees: Double
    let pitchDegrees: Double
}

/// Geometry in Vision's body frame: origin at the root joint between the hips, +y up the body,
/// the subject's left toward +x.
enum BodyFrameGeometry {
    static let ankleHeightRatio: Float = 0.045
    static let rootHeightRatio: Float = 0.53

    /// `cameraOriginMatrix` maps body-frame points into a camera frame that looks down -z with +y up,
    /// so its inverse is the camera's pose in the body frame.
    static func cameraPose(fromCameraOriginMatrix matrix: simd_float4x4) -> simd_float4x4 {
        matrix.inverse
    }

    static func placement(cameraPose: simd_float4x4,
                          leftHip: SIMD3<Float>, rightHip: SIMD3<Float>,
                          leftAnkle: SIMD3<Float>, rightAnkle: SIMD3<Float>,
                          bodyHeight: Float) -> CameraPlacement {
        let camera = SIMD3(cameraPose.columns.3.x, cameraPose.columns.3.y, cameraPose.columns.3.z)
        let lookDirection = -SIMD3(cameraPose.columns.2.x, cameraPose.columns.2.y, cameraPose.columns.2.z)

        // Vision invents legs for cropped subjects, so never place the ground above standard hip height.
        let ankleGround = min(leftAnkle.y, rightAnkle.y) - ankleHeightRatio * bodyHeight
        let groundY = min(ankleGround, -rootHeightRatio * bodyHeight)
        let heightRatio = Double((camera.y - groundY) / bodyHeight)
        let horizontal = Double(hypot(camera.x, camera.z))

        let up = SIMD3<Float>(0, 1, 0)
        var hipAxis = leftHip - rightHip
        hipAxis.y = 0
        let forward = simd_cross(hipAxis, up)
        let toCamera = SIMD3<Float>(camera.x, 0, camera.z)
        let yaw = atan2(simd_dot(up, simd_cross(forward, toCamera)), simd_dot(forward, toCamera))
        let pitch = asin(max(-1, min(1, simd_normalize(lookDirection).y)))

        return CameraPlacement(heightRatio: heightRatio, horizontalDistance: horizontal,
                               subjectYawDegrees: Double(yaw) * 180 / .pi,
                               pitchDegrees: Double(pitch) * 180 / .pi)
    }

    /// Distance from the subject's visible height in pixels, for a camera roughly level with them.
    static func pinholeDistance(focalPixels: Double, subjectHeightMeters: Double,
                                visibleFraction: Double, spanPixels: Double) -> Double? {
        guard focalPixels.isFinite, focalPixels > 0,
              subjectHeightMeters.isFinite, subjectHeightMeters > 0,
              visibleFraction.isFinite, (0...1).contains(visibleFraction),
              spanPixels.isFinite, spanPixels > 1 else { return nil }
        return focalPixels * subjectHeightMeters * visibleFraction / spanPixels
    }

    /// These broad physical bounds catch inverted or degenerate Vision camera matrices without
    /// assuming that every portrait was taken from eye level on a standard lens.
    static func isPlausible(_ placement: CameraPlacement) -> Bool {
        (0.02...2.5).contains(placement.heightRatio) &&
        (0.35...30).contains(placement.horizontalDistance) &&
        placement.subjectYawDegrees.isFinite &&
        placement.pitchDegrees.isFinite &&
        abs(placement.pitchDegrees) <= 80
    }

    /// Two independent distance estimates should be within roughly 30% of each other.
    static func distancesAgree(vision: Double, pinhole: Double) -> Bool {
        guard vision.isFinite, pinhole.isFinite, vision > 0, pinhole > 0 else { return false }
        return (0.7...1.43).contains(vision / pinhole)
    }

    static func scale(bodyHeight: Double, heightIsMeasured: Bool, assumedHeight: Double) -> Double? {
        guard bodyHeight.isFinite, bodyHeight > 0,
              assumedHeight.isFinite, (0.5...2.5).contains(assumedHeight),
              !heightIsMeasured || (0.5...2.5).contains(bodyHeight) else { return nil }
        return heightIsMeasured ? 1 : assumedHeight / bodyHeight
    }
}

enum VisionRunner {
    /// Performs `request`, retrying on the CPU if the default compute device fails to load the model.
    /// Returns the error description when both attempts fail.
    @discardableResult
    static func perform(_ request: VNRequest, on handler: VNImageRequestHandler) -> String? {
        do {
            try handler.perform([request])
            return nil
        } catch {
            let firstError = error.localizedDescription
            guard let stages = try? request.supportedComputeStageDevices else { return firstError }
            var movedToCPU = false
            for (stage, devices) in stages {
                if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                    request.setComputeDevice(cpu, for: stage)
                    movedToCPU = true
                }
            }
            guard movedToCPU else { return firstError }
            do {
                try handler.perform([request])
                return nil
            } catch {
                return "\(firstError); on CPU: \(error.localizedDescription)"
            }
        }
    }
}

struct ShotSpecDiagnostics {
    private(set) var lines: [String] = []
    mutating func add(_ line: String) { lines.append(line) }
    var text: String { lines.joined(separator: "\n") }
}

enum Pose3DReader {
    static func position(_ observation: VNHumanBodyPose3DObservation,
                         _ joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Float>? {
        guard let point = try? observation.recognizedPoint(joint) else { return nil }
        let column = point.position.columns.3
        return SIMD3(column.x, column.y, column.z)
    }

    static func imagePoint(_ observation: VNHumanBodyPose3DObservation,
                           _ joint: VNHumanBodyPose3DObservation.JointName) -> CGPoint? {
        guard let point = try? observation.pointInImage(joint) else { return nil }
        return CGPoint(x: point.x, y: 1 - point.y)
    }

    static func placement(_ observation: VNHumanBodyPose3DObservation) -> CameraPlacement? {
        guard let leftHip = position(observation, .leftHip), let rightHip = position(observation, .rightHip),
              let leftAnkle = position(observation, .leftAnkle), let rightAnkle = position(observation, .rightAnkle)
        else { return nil }
        return BodyFrameGeometry.placement(
            cameraPose: BodyFrameGeometry.cameraPose(fromCameraOriginMatrix: observation.cameraOriginMatrix),
            leftHip: leftHip, rightHip: rightHip, leftAnkle: leftAnkle, rightAnkle: rightAnkle,
            bodyHeight: observation.bodyHeight
        )
    }

    /// Rejects skeletons whose hips or shoulders project well outside the photo; Vision returns
    /// confident-looking but meaningless skeletons for heavily cropped subjects.
    static func isUsable(_ observation: VNHumanBodyPose3DObservation) -> Bool {
        let anchors = [imagePoint(observation, .root), imagePoint(observation, .centerShoulder)]
        return anchors.allSatisfy { point in
            guard let point else { return false }
            return (-0.1...1.1).contains(point.x) && (-0.1...1.2).contains(point.y)
        }
    }

    static func feetAndHeadInFrame(_ observation: VNHumanBodyPose3DObservation) -> Bool {
        let joints: [VNHumanBodyPose3DObservation.JointName] = [.topHead, .leftAnkle, .rightAnkle]
        return joints.allSatisfy { joint in
            guard let point = imagePoint(observation, joint) else { return false }
            return (0...1).contains(point.x) && (0...1.02).contains(point.y)
        }
    }

    /// Bounding box of the projected joints plus room for the feet, and the head-to-ankle span.
    static func subjectBox(_ observation: VNHumanBodyPose3DObservation) -> (box: CGRect, headToAnkle: CGFloat)? {
        let points = observation.availableJointNames.compactMap { imagePoint(observation, $0) }
        guard points.count >= 6, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxY > minY else { return nil }
        let span = maxY - minY
        let bottom = min(1, maxY + span * 0.03)
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: bottom - minY), span)
    }
}

enum Pose2DReader {
    /// Nose-to-ankle span as a fraction of standing height.
    static let noseToAnkleFraction = 0.885

    private static let joints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose), (.neck, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]

    /// Joint positions normalized to the image, top-left origin.
    static func points(_ observation: VNHumanBodyPoseObservation) -> [PoseJoint: CGPoint] {
        var result: [PoseJoint: CGPoint] = [:]
        for (key, name) in joints {
            if let point = try? observation.recognizedPoint(name), point.confidence > 0.3 {
                result[key] = CGPoint(x: point.location.x, y: 1 - point.location.y)
            }
        }
        return result
    }

    static func box(_ points: [PoseJoint: CGPoint]) -> CGRect? {
        guard points.count >= 5, let minX = points.values.map(\.x).min(), let maxX = points.values.map(\.x).max(),
              let minY = points.values.map(\.y).min(), let maxY = points.values.map(\.y).max(),
              maxY > minY else { return nil }
        let span = maxY - minY
        let top = max(0, minY - span * 0.08)
        let bottom = min(1, maxY + span * 0.03)
        return CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    /// Nose-to-ankle span in normalized image height, when the whole body is visible.
    static func noseToAnkle(_ points: [PoseJoint: CGPoint]) -> CGFloat? {
        guard hasUprightBodyEvidence(points), let nose = points[.nose] else { return nil }
        let ankles = [points[.leftAnkle], points[.rightAnkle]].compactMap { $0?.y }
        guard let ankle = ankles.max(), ankle > nose.y else { return nil }
        return ankle - nose.y
    }

    /// Vision's 3D request may synthesize offscreen legs for a cropped portrait. Require the 2D
    /// detector to independently locate the head, torso, and a complete leg before trusting
    /// its camera transform. The other leg may be occluded by the stance or clothing.
    static func hasFullBodyEvidence(_ points: [PoseJoint: CGPoint]) -> Bool {
        let torso: [PoseJoint] = [.nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let valid: (PoseJoint) -> Bool = { joint in
                  guard let point = points[joint] else { return false }
                  return point.x.isFinite && point.y.isFinite &&
                      (0.01...0.99).contains(point.x) && (0.01...0.99).contains(point.y)
              }
        guard torso.allSatisfy(valid), let nose = points[.nose] else { return false }
        let legs: [(PoseJoint, PoseJoint)] = [(.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle)]
        let completeLegs = legs.filter { valid($0.0) && valid($0.1) }
        guard !completeLegs.isEmpty else { return false }
        let jointYs = (torso + completeLegs.flatMap { [$0.0, $0.1] }).compactMap { points[$0]?.y }
        return (jointYs.max() ?? 0) - (jointYs.min() ?? 0) >= 0.25 &&
            completeLegs.contains { (points[$0.1]?.y ?? 0) - nose.y >= 0.15 }
    }

    /// A 2D image span estimates metric distance only when legs extend below an upright torso.
    static func hasUprightBodyEvidence(_ points: [PoseJoint: CGPoint]) -> Bool {
        guard hasFullBodyEvidence(points), let nose = points[.nose],
              let shoulders = meanY(points, .leftShoulder, .rightShoulder),
              let hips = meanY(points, .leftHip, .rightHip),
              nose.y + 0.02 < shoulders, shoulders + 0.03 < hips else { return false }
        let legs: [(PoseJoint, PoseJoint)] = [(.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle)]
        return legs.contains { leg in
            guard let knee = points[leg.0]?.y, let ankle = points[leg.1]?.y else { return false }
            return hips + 0.04 < knee && knee + 0.04 < ankle && ankle - nose.y >= 0.3
        }
    }

    /// The 2D detector can return several people while Vision's 3D detector returns one.
    /// A camera pose must describe the same person whose 2D joints and outline form the guide.
    static func boxesLikelySamePerson(_ first: CGRect, _ second: CGRect) -> Bool {
        guard first.width > 0, first.height > 0, second.width > 0, second.height > 0 else { return false }
        let overlap = first.intersection(second)
        guard !overlap.isNull else { return false }
        let area = overlap.width * overlap.height
        let smaller = min(first.width * first.height, second.width * second.height)
        return area / smaller >= 0.4
    }

    private static func meanY(_ points: [PoseJoint: CGPoint], _ left: PoseJoint, _ right: PoseJoint) -> CGFloat? {
        guard let leftPoint = points[left], let rightPoint = points[right] else { return nil }
        return (leftPoint.y + rightPoint.y) / 2
    }
}

enum ShotSpecEstimator {
    static let defaultSubjectHeight = 1.7

    static func estimate(image: UIImage, imageData: Data? = nil,
                         subjectHeightMeters: Double = defaultSubjectHeight) async -> (spec: ShotSpec, diagnostics: ShotSpecDiagnostics) {
        guard let cgImage = image.cgImage else {
            return (ShotSpec(source: .fallback, subjectHeightMeters: subjectHeightMeters), ShotSpecDiagnostics())
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            estimate(cgImage: cgImage, orientation: orientation, imageData: imageData,
                     subjectHeightMeters: subjectHeightMeters)
        }.value
    }

    static func estimate(cgImage: CGImage, orientation: CGImagePropertyOrientation, imageData: Data?,
                         subjectHeightMeters: Double) -> (spec: ShotSpec, diagnostics: ShotSpecDiagnostics) {
        var log = ShotSpecDiagnostics()
        let rawSize = CGSize(width: cgImage.width, height: cgImage.height)
        let size = orientation.swapsDimensions ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
        let exifMM = imageData.flatMap(LensModel.equivalentFocalLength(imageData:))
        let focalSource: ShotSpec.FocalSource = exifMM.map { .exif(millimeters: $0) } ?? .assumedPhoneLens
        let focalPixels = LensModel.focalLengthPixels(imageSize: size, equivalentMM: exifMM ?? LensModel.phoneMainEquivalentMM)
        log.add("image \(Int(size.width))x\(Int(size.height)) orientation \(orientation.rawValue)")
        log.add("focal \(fmt(focalPixels)) px from \(exifMM.map { "EXIF \(fmt($0)) mm" } ?? "assumed \(fmt(LensModel.phoneMainEquivalentMM)) mm phone lens")")
        let intrinsics = LensModel.intrinsicsData(width: cgImage.width, height: cgImage.height, focalPixels: focalPixels)
        let options: [VNImageOption: Any] = [.cameraIntrinsics: intrinsics as CFData]
        // An original HEIC/JPEG may contain calibration and depth auxiliaries that have already
        // been discarded by UIImage's CGImage. Let Vision decode the original when available.
        let handler = imageData.map { VNImageRequestHandler(data: $0, orientation: orientation, options: options) }
            ?? VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: options)
        let pose3D = VNDetectHumanBodyPose3DRequest()
        let pose2D = VNDetectHumanBodyPoseRequest()
        let horizon = VNDetectHorizonRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        // Run separately so one unavailable model does not block the others.
        let requests: [(String, VNRequest)] = [("3D pose", pose3D), ("2D pose", pose2D),
                                               ("horizon", horizon), ("segmentation", segmentation)]
        for (name, request) in requests {
            log.add("\(name): \(VisionRunner.perform(request, on: handler).map { "FAILED \($0)" } ?? "ok")")
        }

        let points2D = pose2D.results?.first.map(Pose2DReader.points) ?? [:]
        let horizonDegrees = horizon.results?.first.map { Double($0.angle) * 180 / .pi }
        let personBox = Pose2DReader.box(points2D)
        let silhouette = segmentation.results?.first.map {
            silhouettePoints(mask: $0.pixelBuffer, personBox: personBox)
        } ?? []
        log.add("horizon \(horizonDegrees.map(fmt) ?? "none"), silhouette \(silhouette.count) points, 2D joints \(points2D.count)")
        let aspect = size.width / max(size.height, 1)

        if let body = pose3D.results?.first {
            logRaw(body, into: &log)
            if !Pose3DReader.isUsable(body) { log.add("3D skeleton rejected: hips or shoulders project outside the photo") }
        }
        let fullBodyEvidence = Pose2DReader.hasFullBodyEvidence(points2D)
        let uprightEvidence = Pose2DReader.hasUprightBodyEvidence(points2D)
        if !fullBodyEvidence { log.add("full-body 2D evidence unavailable; camera geometry will be withheld") }
        if let body = pose3D.results?.first, fullBodyEvidence,
           let personBox, let projected = Pose3DReader.subjectBox(body),
           Pose2DReader.boxesLikelySamePerson(personBox, projected.box),
           Pose3DReader.isUsable(body), let placement = Pose3DReader.placement(body),
           BodyFrameGeometry.isPlausible(placement),
           let scale = BodyFrameGeometry.scale(
                bodyHeight: Double(body.bodyHeight), heightIsMeasured: body.heightEstimation == .measured,
                assumedHeight: subjectHeightMeters) {
            let measuredHeight = body.heightEstimation == .measured
            let resolvedHeight = Double(body.bodyHeight) * scale
            let distance = placement.horizontalDistance * scale
            let pinhole = (uprightEvidence ? Pose2DReader.noseToAnkle(points2D) : nil).flatMap {
                BodyFrameGeometry.pinholeDistance(focalPixels: focalPixels, subjectHeightMeters: resolvedHeight,
                                                  visibleFraction: Pose2DReader.noseToAnkleFraction,
                                                  spanPixels: Double($0 * size.height))
            }
            let agreement = pinhole.map { BodyFrameGeometry.distancesAgree(vision: distance, pinhole: $0) }
            log.add("placement heightRatio \(fmt(placement.heightRatio)) yaw \(fmt(placement.subjectYawDegrees))° pitch \(fmt(placement.pitchDegrees))°")
            log.add("distance vision \(fmt(distance)) m, pinhole \(pinhole.map(fmt) ?? "-") m, agreement \(agreement.map { String(describing: $0) } ?? "unavailable")")
            // An EXIF focal length makes the pinhole estimate independent enough to disqualify
            // a contradictory 3D camera pose. An assumed lens cannot support that conclusion.
            if exifMM == nil || agreement != false {
                let spec = ShotSpec(source: .pose3D, cameraHeightRatio: placement.heightRatio, distanceMeters: distance,
                                distanceIsApproximate: !measuredHeight || exifMM == nil,
                                pitchDegrees: placement.pitchDegrees,
                                subjectYawDegrees: placement.subjectYawDegrees, horizonDegrees: horizonDegrees,
                                subjectBox: personBox, silhouette: silhouette,
                                subjectHeightMeters: resolvedHeight, focalSource: focalSource, imageAspect: aspect)
                return (spec, log)
            }
            log.add("3D camera pose rejected: EXIF-calibrated image span disagrees with Vision distance")
        } else if pose3D.results?.first != nil {
            log.add("3D camera pose rejected: missing full-body evidence or implausible transform")
        }

        if uprightEvidence, let span = Pose2DReader.noseToAnkle(points2D) {
            let distance = BodyFrameGeometry.pinholeDistance(
                focalPixels: focalPixels, subjectHeightMeters: subjectHeightMeters,
                visibleFraction: Pose2DReader.noseToAnkleFraction, spanPixels: Double(span * size.height))
            log.add("2D fallback distance \(distance.map(fmt) ?? "-") m")
            let spec = ShotSpec(source: .pose2D, distanceMeters: distance, horizonDegrees: horizonDegrees,
                                subjectBox: personBox, silhouette: silhouette,
                                subjectHeightMeters: subjectHeightMeters, focalSource: focalSource, imageAspect: aspect)
            return (spec, log)
        }

        log.add("no full body found; using fallback")
        let spec = ShotSpec(source: .fallback, horizonDegrees: horizonDegrees, subjectBox: personBox,
                            silhouette: silhouette, subjectHeightMeters: subjectHeightMeters,
                            focalSource: focalSource, imageAspect: aspect)
        return (spec, log)
    }

    static func silhouettePoints(mask: CVPixelBuffer, personBox: CGRect? = nil) -> [CGPoint] {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 256
        let handler = VNImageRequestHandler(cvPixelBuffer: mask, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return [] }
        let contours = observation.topLevelContours.compactMap { contour -> [CGPoint]? in
            guard let simplified = try? contour.polygonApproximation(epsilon: 0.003) else { return nil }
            return simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
        }
        return selectSilhouette(contours: contours, personBox: personBox)
    }

    /// A segmentation mask can contain several people. Match its contour to the pose used for
    /// the reference guide, instead of choosing whichever outline has the most vertices.
    static func selectSilhouette(contours: [[CGPoint]], personBox: CGRect?) -> [CGPoint] {
        let candidates = contours.compactMap { points -> (points: [CGPoint], bounds: CGRect, area: CGFloat)? in
            guard points.count >= 3, points.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
            }) else { return nil }
            let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            guard bounds.width >= 0.03, bounds.height >= 0.08 else { return nil }
            let doubleArea = zip(points, points.dropFirst() + points.prefix(1)).reduce(CGFloat.zero) {
                $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
            }
            let area = abs(doubleArea) / 2
            guard area >= 0.005 else { return nil }
            return (points, bounds, area)
        }
        guard !candidates.isEmpty else { return [] }
        guard let personBox else {
            let ranked = candidates.sorted { $0.area > $1.area }
            return ranked.count == 1 || ranked[0].area >= 2 * ranked[1].area ? ranked[0].points : []
        }
        guard personBox.width > 0.01, personBox.height > 0.03 else { return [] }
        let ranked = candidates.compactMap { candidate -> (points: [CGPoint], score: CGFloat)? in
            let overlap = candidate.bounds.intersection(personBox)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            let overlapArea = overlap.width * overlap.height
            let poseCoverage = overlapArea / (personBox.width * personBox.height)
            let contourCoverage = overlapArea / (candidate.bounds.width * candidate.bounds.height)
            guard poseCoverage >= 0.5, contourCoverage >= 0.08,
                  candidate.bounds.contains(CGPoint(x: personBox.midX, y: personBox.midY)) else { return nil }
            return (candidate.points, poseCoverage * 0.7 + contourCoverage * 0.3)
        }.sorted { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.count == 1 || best.score >= ranked[1].score * 1.25 else { return [] }
        return best.points
    }

    private static func logRaw(_ body: VNHumanBodyPose3DObservation, into log: inout ShotSpecDiagnostics) {
        let matrix = body.cameraOriginMatrix
        log.add("bodyHeight \(fmt(Double(body.bodyHeight))) (\(body.heightEstimation == .measured ? "measured" : "reference"))")
        log.add("cameraOriginMatrix\n\(describe(matrix))")
        log.add("camera in body frame \(describe(BodyFrameGeometry.cameraPose(fromCameraOriginMatrix: matrix).columns.3))")
        if let rootFromCamera = try? body.cameraRelativePosition(.root) {
            log.add("root relative to camera \(describe(rootFromCamera.columns.3))")
        }
        for joint in body.availableJointNames {
            let position = Pose3DReader.position(body, joint).map { describe(SIMD4($0, 1)) } ?? "-"
            let image = Pose3DReader.imagePoint(body, joint).map { "(\(fmt(Double($0.x))), \(fmt(Double($0.y))))" } ?? "-"
            log.add("  \(joint.rawValue.rawValue): \(position) image \(image)")
        }
    }

    private static func describe(_ matrix: simd_float4x4) -> String {
        (0..<4).map { row in
            "  [" + (0..<4).map { fmt(Double(matrix[$0][row])) }.joined(separator: ", ") + "]"
        }.joined(separator: "\n")
    }

    private static func describe(_ vector: SIMD4<Float>) -> String {
        "(\(fmt(Double(vector.x))), \(fmt(Double(vector.y))), \(fmt(Double(vector.z))))"
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }

}

extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
    }
}
