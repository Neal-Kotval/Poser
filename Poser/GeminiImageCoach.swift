import FirebaseAILogic
import FirebaseCore
import UIKit

/// Optional cloud descriptions. Vision remains the source of pose measurements and scores.
@MainActor
enum GeminiImageCoach {
    static var isConfigured: Bool { FirebaseApp.app() != nil }

    static func describeReference(_ image: UIImage, hasMeasuredPose: Bool) async throws -> String {
        let prompt = """
        You are a photography pose coach. Describe only what is visible in this reference image.
        Identify the main human subject, then describe their head direction, shoulders, arms,
        torso, legs, camera framing, and light in at most three short sentences. If the person
        is cropped or a body part is hidden, say so. If no person is visible, say that clearly.
        Do not identify who the person is. Do not invent exact camera distance, height, angles,
        or a numeric pose score. \(hasMeasuredPose ? "The app has measured body joints separately." : "The app could not measure a complete body pose from this image.")
        """
        return try await generate(image, prompt: prompt)
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
            .generativeModel(modelName: "gemini-3.8-flash")
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
