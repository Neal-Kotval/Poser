import CoreGraphics
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
        guard spanPixels > 1 else { return nil }
        return focalPixels * subjectHeightMeters * visibleFraction / spanPixels
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
        guard let nose = points[.nose] else { return nil }
        let ankles = [points[.leftAnkle], points[.rightAnkle]].compactMap { $0?.y }
        guard let ankle = ankles.max(), ankle > nose.y else { return nil }
        return ankle - nose.y
    }
}

enum ShotSpecEstimator {
    static let defaultSubjectHeight = 1.7
    private static let headToAnkleFraction = 1 - Double(BodyFrameGeometry.ankleHeightRatio)
    private static let noseToAnkleFraction = 0.885

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
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation,
                                            options: [.cameraIntrinsics: intrinsics as CFData])
        let pose3D = VNDetectHumanBodyPose3DRequest()
        let pose2D = VNDetectHumanBodyPoseRequest()
        let horizon = VNDetectHorizonRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        // Run separately so one unavailable model does not block the others.
        do { try handler.perform([pose3D]) } catch { log.add("3D pose failed: \(error.localizedDescription)") }
        try? handler.perform([pose2D])
        try? handler.perform([horizon])
        try? handler.perform([segmentation])

        let points2D = pose2D.results?.first.map(Pose2DReader.points) ?? [:]
        let horizonDegrees = horizon.results?.first.map { Double($0.angle) * 180 / .pi }
        let silhouette = segmentation.results?.first.map { silhouettePoints(mask: $0.pixelBuffer) } ?? []
        log.add("horizon \(horizonDegrees.map(fmt) ?? "none"), silhouette \(silhouette.count) points, 2D joints \(points2D.count)")
        let aspect = size.width / max(size.height, 1)

        if let body = pose3D.results?.first {
            logRaw(body, into: &log)
            if !Pose3DReader.isUsable(body) { log.add("3D skeleton rejected: hips or shoulders project outside the photo") }
        }
        if let body = pose3D.results?.first, Pose3DReader.isUsable(body), let placement = Pose3DReader.placement(body) {
            let scale = subjectHeightMeters / Double(body.bodyHeight)
            let distance = placement.horizontalDistance * scale
            let projected = Pose3DReader.subjectBox(body)
            let anklesSeen = points2D[.leftAnkle] != nil || points2D[.rightAnkle] != nil
            let pinhole = anklesSeen && Pose3DReader.feetAndHeadInFrame(body) ? projected.flatMap {
                BodyFrameGeometry.pinholeDistance(focalPixels: focalPixels, subjectHeightMeters: subjectHeightMeters,
                                                  visibleFraction: headToAnkleFraction,
                                                  spanPixels: Double($0.headToAnkle * size.height))
            } : nil
            let agreement = pinhole.map { distance / $0 }
            let approximate = agreement.map { !(0.7...1.43).contains($0) } ?? true
            log.add("placement heightRatio \(fmt(placement.heightRatio)) yaw \(fmt(placement.subjectYawDegrees))° pitch \(fmt(placement.pitchDegrees))°")
            log.add("distance vision \(fmt(distance)) m, pinhole \(pinhole.map(fmt) ?? "-") m, approximate \(approximate)")
            let spec = ShotSpec(source: .pose3D, cameraHeightRatio: placement.heightRatio, distanceMeters: distance,
                                distanceIsApproximate: approximate, pitchDegrees: placement.pitchDegrees,
                                subjectYawDegrees: placement.subjectYawDegrees, horizonDegrees: horizonDegrees,
                                subjectBox: projected?.box ?? Pose2DReader.box(points2D), silhouette: silhouette,
                                subjectHeightMeters: subjectHeightMeters, focalSource: focalSource, imageAspect: aspect)
            return (spec, log)
        }

        if let span = Pose2DReader.noseToAnkle(points2D) {
            let distance = BodyFrameGeometry.pinholeDistance(
                focalPixels: focalPixels, subjectHeightMeters: subjectHeightMeters,
                visibleFraction: noseToAnkleFraction, spanPixels: Double(span * size.height))
            log.add("2D fallback distance \(distance.map(fmt) ?? "-") m")
            let spec = ShotSpec(source: .pose2D, distanceMeters: distance, horizonDegrees: horizonDegrees,
                                subjectBox: Pose2DReader.box(points2D), silhouette: silhouette,
                                subjectHeightMeters: subjectHeightMeters, focalSource: focalSource, imageAspect: aspect)
            return (spec, log)
        }

        log.add("no full body found; using fallback")
        let spec = ShotSpec(source: .fallback, horizonDegrees: horizonDegrees, subjectBox: Pose2DReader.box(points2D),
                            silhouette: silhouette, subjectHeightMeters: subjectHeightMeters,
                            focalSource: focalSource, imageAspect: aspect)
        return (spec, log)
    }

    private static func silhouettePoints(mask: CVPixelBuffer) -> [CGPoint] {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 256
        let handler = VNImageRequestHandler(cvPixelBuffer: mask, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let largest = observation.topLevelContours.max(by: { $0.pointCount < $1.pointCount }),
              let simplified = try? largest.polygonApproximation(epsilon: 0.003) else { return [] }
        return simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
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
