import Foundation
import CoreGraphics

/// Captures single-frame screenshots of the main display using CGDisplayCreateImage.
/// Uses CoreGraphics directly, not ScreenCaptureKit, so there is no recording
/// indicator and no app-visible screenshot notifications.
///
/// Screen sharing coexistence: CGDisplayCreateImage is a read-only,
/// non-exclusive API. It does NOT interfere with Zoom, Teams, FaceTime,
/// or any other app's ScreenCaptureKit-based screen sharing sessions.
/// Both can run simultaneously without conflict.
final class ScreenCapture: Sendable {
    private let logger = DualLogger(category: "ScreenCapture")

    /// Maximum capture width in pixels. Images wider than this are downscaled
    /// proportionally to keep OCR fast and storage lean.
    private let maxWidth: CGFloat = 1920

    /// Capture a screenshot of the main display.
    /// Returns a CGImage, or nil if capture fails (e.g., no permission).
    func captureMainDisplay() throws -> CGImage? {
        guard let raw = CGDisplayCreateImage(CGMainDisplayID()) else {
            logger.error("CGDisplayCreateImage returned nil (no display or no permission)")
            return nil
        }

        // Downscale if wider than maxWidth (preserves aspect ratio)
        let image = downscaleIfNeeded(raw)
        logger.debug("Captured screenshot: \(image.width)x\(image.height)")
        return image
    }

    /// Proportionally downscale an image if it exceeds `maxWidth`.
    private func downscaleIfNeeded(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        guard width > maxWidth else { return image }

        let scale = maxWidth / width
        let newWidth = Int(width * scale)
        let newHeight = Int(CGFloat(image.height) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            logger.warning("Failed to create downscale context, returning original image")
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let scaled = context.makeImage() else {
            logger.warning("Failed to create scaled image, returning original")
            return image
        }
        return scaled
    }
}
