import Foundation
import Vision
import CoreGraphics

/// Processes screenshots using Apple's Vision framework to extract text via OCR.
/// Uses VNRecognizeTextRequest with accurate recognition and language correction.
final class OCRProcessor: Sendable {
    private let logger = DualLogger(category: "OCR")

    /// Result of OCR processing on a single image.
    struct OCRResult: Sendable {
        /// All recognized text concatenated in reading order (top-to-bottom, left-to-right).
        let fullText: String

        /// Individual text regions with bounding boxes and confidence.
        // TODO: These regions (bounding boxes) are computed but never persisted to the database.
        // CaptureRecord does not store ocrRegions. The overhead is minimal compared to the OCR
        // pass itself, but if spatial queries are never needed, this could be removed to save
        // allocations. Keep for now in case spatial search is added later.
        let regions: [OCRRegion]
    }

    /// Perform OCR on a CGImage. Runs synchronously on the calling thread
    /// (should be called from a background context).
    func recognizeText(in image: CGImage) throws -> OCRResult {
        var results: [VNRecognizedTextObservation] = []
        var recognitionError: Error?

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                recognitionError = error
                return
            }
            results = request.results as? [VNRecognizedTextObservation] ?? []
        }

        // Configure for best accuracy
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Revision 3 is the latest as of macOS 14
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        if let error = recognitionError {
            throw error
        }

        // Sort observations by position: top-to-bottom, then left-to-right
        // Vision uses normalized coordinates with origin at bottom-left,
        // so we sort by descending Y (top first), then ascending X (left first).
        let sorted = results.sorted { a, b in
            let aY = a.boundingBox.origin.y
            let bY = b.boundingBox.origin.y
            if abs(aY - bY) > 0.02 { // Same "line" threshold
                return aY > bY // Higher Y = higher on screen
            }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }

        var regions: [OCRRegion] = []
        var textLines: [String] = []

        for observation in sorted {
            guard let candidate = observation.topCandidates(1).first else { continue }

            let region = OCRRegion(
                text: candidate.string,
                bounds: CodableCGRect(observation.boundingBox),
                confidence: candidate.confidence
            )
            regions.append(region)
            textLines.append(candidate.string)
        }

        let fullText = textLines.joined(separator: "\n")
        logger.debug("OCR recognized \(regions.count) text regions, \(fullText.count) characters")

        return OCRResult(fullText: fullText, regions: regions)
    }

    /// Maximum number of separate crop regions before falling back to full-screen OCR.
    /// Many scattered small crops is slower than one full OCR pass.
    private static let maxRegionsBeforeFallback = 8

    /// Perform OCR on multiple cropped regions from a full screenshot.
    /// Used for delta frames where only changed portions of the screen need OCR.
    ///
    /// For each `ChangedRegion`, runs `VNRecognizeTextRequest` on the `croppedImage`
    /// and translates bounding boxes back to full-image coordinates.
    ///
    /// If more than 8 separate regions are provided, falls back to full-screen OCR
    /// on the provided `fullImage` (many scattered small crops is slower).
    ///
    /// - Parameters:
    ///   - regions: Changed regions with cropped images for OCR.
    ///   - fullImage: The full screenshot image (used for fallback).
    ///   - fullImageSize: Size of the full image in pixels.
    /// - Returns: OCR result with text from changed regions only.
    func recognizeText(
        inRegions regions: [ChangedRegion],
        fullImage: CGImage,
        fullImageSize: CGSize
    ) throws -> OCRResult {
        guard !regions.isEmpty else {
            return OCRResult(fullText: "", regions: [])
        }

        // Fallback: too many scattered regions, full-screen OCR is faster
        if regions.count > Self.maxRegionsBeforeFallback {
            logger.debug("Too many regions (\(regions.count)), falling back to full OCR")
            return try recognizeText(in: fullImage)
        }

        var allOCRRegions: [OCRRegion] = []
        var allTextLines: [String] = []

        for changedRegion in regions {
            let cropResult = try recognizeTextInCrop(
                croppedImage: changedRegion.croppedImage,
                cropBounds: changedRegion.bounds,
                fullImageSize: fullImageSize
            )

            allOCRRegions.append(contentsOf: cropResult.regions)
            if !cropResult.fullText.isEmpty {
                allTextLines.append(cropResult.fullText)
            }
        }

        // Sort all regions by position in full image space:
        // top-to-bottom (descending Y in normalized coords), then left-to-right
        allOCRRegions.sort { a, b in
            let aY = a.bounds.y
            let bY = b.bounds.y
            if abs(aY - bY) > 0.02 {
                return aY > bY
            }
            return a.bounds.x < b.bounds.x
        }

        // Re-join text in sorted order
        let sortedText = allOCRRegions.map(\.text).joined(separator: "\n")
        let finalText = sortedText.isEmpty ? allTextLines.joined(separator: "\n") : sortedText

        logger.debug("Partial OCR: \(regions.count) regions, \(allOCRRegions.count) text regions, \(finalText.count) characters")

        return OCRResult(fullText: finalText, regions: allOCRRegions)
    }

    /// Run OCR on a single cropped image and translate coordinates to full-image space.
    private func recognizeTextInCrop(
        croppedImage: CGImage,
        cropBounds: CGRect,
        fullImageSize: CGSize
    ) throws -> OCRResult {
        var results: [VNRecognizedTextObservation] = []
        var recognitionError: Error?

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                recognitionError = error
                return
            }
            results = request.results as? [VNRecognizedTextObservation] ?? []
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
        try handler.perform([request])

        if let error = recognitionError {
            throw error
        }

        var regions: [OCRRegion] = []
        var textLines: [String] = []

        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }

            // Translate bounding box from crop-local normalized coords to full-image normalized coords.
            // Vision bounding boxes are normalized [0,1] with origin at bottom-left.
            // cropBounds is in pixel space (top-left origin from CGImage.cropping).
            let cropBox = observation.boundingBox

            // Convert crop pixel bounds to full-image normalized coords (top-left origin)
            let cropTopInFull = cropBounds.origin.y / fullImageSize.height
            let cropHeightNorm = cropBounds.height / fullImageSize.height
            let cropLeftInFull = cropBounds.origin.x / fullImageSize.width
            let cropWidthNorm = cropBounds.width / fullImageSize.width

            // Vision's y=0 is bottom of crop, y=1 is top of crop.
            // In full-image top-left coords: top of crop = cropTopInFull,
            // bottom of crop = cropTopInFull + cropHeightNorm.
            // Vision box top (in full image) = cropTopInFull + (1 - cropBox.maxY) * cropHeightNorm
            let fullBox = CGRect(
                x: cropLeftInFull + cropBox.origin.x * cropWidthNorm,
                y: cropTopInFull + (1.0 - cropBox.origin.y - cropBox.height) * cropHeightNorm,
                width: cropBox.width * cropWidthNorm,
                height: cropBox.height * cropHeightNorm
            )

            let region = OCRRegion(
                text: candidate.string,
                bounds: CodableCGRect(fullBox),
                confidence: candidate.confidence
            )
            regions.append(region)
            textLines.append(candidate.string)
        }

        let fullText = textLines.joined(separator: "\n")
        return OCRResult(fullText: fullText, regions: regions)
    }
}
