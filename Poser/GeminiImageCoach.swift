import FirebaseAILogic
import FirebaseCore
import UIKit

struct GeminiReferencePlan: Decodable, Equatable {
    enum PoseStyle: String, Decodable { case standing, walking, seated, leaning, unknown }
    enum CameraLevel: String, Decodable { case ground, knee, hip, chest, eye, overhead, unknown }
    enum Tilt: String, Decodable { case up, level, down, unknown }
    enum Distance: String, Decodable { case close, medium, far, unknown }

    let hasPerson: Bool
    let summary: String
    let poseCue: String
    let framingCue: String
    let lightCue: String
    let poseStyle: PoseStyle
    let cameraLevel: CameraLevel
    let tilt: Tilt
    let distance: Distance
}

/// Optional cloud descriptions. Vision remains the source of pose measurements and scores.
@MainActor
enum GeminiImageCoach {
    static var isConfigured: Bool { FirebaseApp.app() != nil }

    static func planReference(_ image: UIImage, visionHasPerson: Bool,
                              hasMeasuredPose: Bool) async throws -> GeminiReferencePlan {
        guard isConfigured else { throw GeminiCoachError.notConfigured }
        let schema = Schema.object(properties: [
            "hasPerson": .boolean(),
            "summary": .string(),
            "poseCue": .string(),
            "framingCue": .string(),
            "lightCue": .string(),
            "poseStyle": .enumeration(values: ["standing", "walking", "seated", "leaning", "unknown"]),
            "cameraLevel": .enumeration(values: ["ground", "knee", "hip", "chest", "eye", "overhead", "unknown"]),
            "tilt": .enumeration(values: ["up", "level", "down", "unknown"]),
            "distance": .enumeration(values: ["close", "medium", "far", "unknown"])
        ])
        let config = GenerationConfig(maxOutputTokens: 300,
                                      responseMIMEType: "application/json", responseSchema: schema)
        let model = FirebaseAI.firebaseAI(backend: .googleAI())
            .generativeModel(modelName: "gemini-3.5-flash-lite", generationConfig: config,
                             requestOptions: RequestOptions(timeout: 12))
        let prompt = """
        Prepare a concise plan for recreating this reference photograph. Describe only visible cues.
        summary: one short instruction about the overall shot. poseCue: one short instruction for
        the subject's visible body pose. framingCue: one short instruction for subject placement.
        lightCue: one short instruction about visible light. Use empty strings for unavailable cues.
        Classify poseStyle, cameraLevel, tilt, and distance only when the image gives a clear cue;
        otherwise choose unknown. Distance means relative framing (close, medium, far), not meters.
        Camera level and tilt are qualitative starting suggestions, not measurements of the original
        camera. If a person is cropped, do not infer hidden limbs. If no person is visible, set
        hasPerson false, poseStyle unknown, and poseCue empty. Do not identify anyone or invent
        numeric height, distance, angles, lens settings, or pose scores.
        The app's Vision analysis \(visionHasPerson ? "found" : "did not find") a person and
        \(hasMeasuredPose ? "measured some visible joints." : "could not measure a usable pose.")
        """
        let response = try await model.generateContent(prepared(image), prompt)
        guard let text = response.text, let data = text.data(using: .utf8),
              let plan = try? JSONDecoder().decode(GeminiReferencePlan.self, from: data),
              !plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiCoachError.emptyResponse
        }
        return plan
    }

    static func compare(reference: UIImage, shot: UIImage, measuredScore: Int?,
                        measuredCue: String?) async throws -> String {
        let measurement = measuredScore.map { "The app's joint-based pose score is \($0)%." }
            ?? "The app could not calculate a reliable joint-based pose score."
        let cue = measuredCue.map { "The app's measured cue is: \($0)." } ?? ""
        let prompt = """
        You are a concise photography coach. The first image is the reference; the second is
        the user's shot. Compare the visible subject's pose, framing, and light. Give at most
        two concrete adjustments the photographer or subject can make. \(measurement) \(cue)
        Treat the app's measurements as authoritative. Do not invent or change a numeric score,
        exact camera geometry, hidden limb positions, or the person's identity. If either image
        lacks a visible person, say that before giving advice.
        """
        return try await generate(reference, shot, prompt: prompt)
    }

    private static func generate(_ images: UIImage..., prompt: String) async throws -> String {
        guard isConfigured else { throw GeminiCoachError.notConfigured }
        let model = FirebaseAI.firebaseAI(backend: .googleAI())
            .generativeModel(modelName: "gemini-3.5-flash-lite")
        let response: GenerateContentResponse
        switch images.count {
        case 1: response = try await model.generateContent(prepared(images[0]), prompt)
        case 2: response = try await model.generateContent(prepared(images[0]), prepared(images[1]), prompt)
        default: throw GeminiCoachError.invalidImages
        }
        guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw GeminiCoachError.emptyResponse }
        return text
    }

    private static func prepared(_ image: UIImage) -> UIImage {
        let width = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
        let longest = max(width, height)
        guard longest > 1600 else { return image }
        let size = CGSize(width: width * 1600 / longest, height: height * 1600 / longest)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

enum GeminiCoachError: LocalizedError {
    case notConfigured, invalidImages, emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Gemini guidance is not connected yet."
        case .invalidImages: "The photos could not be analyzed."
        case .emptyResponse: "Gemini did not return guidance. Please try again."
        }
    }
}
