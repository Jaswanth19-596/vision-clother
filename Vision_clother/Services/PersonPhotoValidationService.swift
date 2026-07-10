//
//  PersonPhotoValidationService.swift
//  Vision_clother
//
//  Gatekeeper for Manual Outfit Pairing's virtual try-on (PRD.md's Visual
//  Generation Canvas, extended to a user-selected outfit). Runs entirely
//  on-device via Apple's Vision framework — CLAUDE.md guardrail #4's
//  on-device philosophy — so an unsuitable photo (multiple people, no full
//  body visible, unusable lighting) never leaves the device just to be
//  rejected.
//
//  These are heuristic checks, not a guarantee of a good try-on result:
//  human/body-pose detection and a crude average-brightness read are what
//  Vision offers on-device today. "Front-facing" has no reliable on-device
//  signal worth gating on, so it's not checked here — only the blocking
//  requirements (single person, full body, usable lighting) are enforced.
//

import CoreImage
import Foundation
import Vision

protocol PersonPhotoValidationService {
    /// Throws a `PersonPhotoValidationError` if the photo isn't usable;
    /// returns normally otherwise.
    func validate(imageData: Data) async throws
}

enum PersonPhotoValidationError: Error, LocalizedError, Equatable {
    case invalidImage
    case noPersonFound
    case multiplePeopleFound
    case notFullBody
    case poorLighting
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read."
        case .noPersonFound:
            return "Couldn't find a person in that photo. Try a clear, full-body shot."
        case .multiplePeopleFound:
            return "That photo has more than one person in it. Use a photo of just you."
        case .notFullBody:
            return "Move back so your whole body — head to feet — is in frame."
        case .poorLighting:
            return "That photo is too dark or too bright. Try better lighting."
        case .processingFailed:
            return "Something went wrong checking that photo. Try again."
        }
    }
}

final class VisionPersonPhotoValidationService: PersonPhotoValidationService {
    /// Below this per-joint confidence, a landmark is treated as "not
    /// visible" rather than trusted.
    private let minimumJointConfidence: Float = 0.3
    /// Average-luminance band (0-1) outside which a photo is rejected as
    /// unusable — deliberately lenient since this is a coarse proxy for
    /// "good lighting", not a real exposure/metering analysis.
    private let minimumBrightness: CGFloat = 0.12
    private let maximumBrightness: CGFloat = 0.92

    private let context = CIContext()

    func validate(imageData: Data) async throws {
        guard let ciImage = CIImage(data: imageData) else {
            throw PersonPhotoValidationError.invalidImage
        }

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let humanRequest = VNDetectHumanRectanglesRequest()
        let poseRequest = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([humanRequest, poseRequest])
        } catch {
            throw PersonPhotoValidationError.processingFailed
        }

        let peopleCount = humanRequest.results?.count ?? 0
        guard peopleCount > 0 else { throw PersonPhotoValidationError.noPersonFound }
        guard peopleCount == 1 else { throw PersonPhotoValidationError.multiplePeopleFound }

        guard let pose = poseRequest.results?.first else {
            throw PersonPhotoValidationError.notFullBody
        }
        try checkFullBodyVisible(pose)
        try checkLighting(of: ciImage)
    }

    private func checkFullBodyVisible(_ observation: VNHumanBodyPoseObservation) throws {
        let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
            .leftShoulder, .rightShoulder,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
        ]

        guard let points = try? observation.recognizedPoints(.all) else {
            throw PersonPhotoValidationError.notFullBody
        }

        for joint in requiredJoints {
            guard let point = points[joint], point.confidence >= minimumJointConfidence else {
                throw PersonPhotoValidationError.notFullBody
            }
        }
    }

    private func checkLighting(of image: CIImage) throws {
        guard
            let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: image.extent),
            ]),
            let outputImage = averageFilter.outputImage
        else {
            throw PersonPhotoValidationError.processingFailed
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let brightness = (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / 3.0 / 255.0
        guard brightness >= minimumBrightness, brightness <= maximumBrightness else {
            throw PersonPhotoValidationError.poorLighting
        }
    }
}

// MARK: - Mock for previews/tests — never touches Vision/CoreImage.

struct MockPersonPhotoValidationService: PersonPhotoValidationService {
    var errorToThrow: PersonPhotoValidationError?

    func validate(imageData: Data) async throws {
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
