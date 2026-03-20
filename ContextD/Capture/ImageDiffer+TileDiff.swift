import Foundation

/// SIMD-accelerated and scalar tile diff implementations for ImageDiffer.
extension ImageDiffer {

    /// SIMD-accelerated total BGR diff for a tile. Processes 4 pixels (16 bytes) per
    /// iteration via `SIMD16<UInt8>`, with scalar cleanup for remainder pixels.
    /// Supports optional early exit when `earlyExitThreshold` is exceeded.
    /// Returns the raw sum of per-channel absolute differences (BGR only, alpha skipped).
    func tileDiffSIMD(
        currentPixels: UnsafeMutablePointer<UInt8>,
        previousPixels: UnsafeMutablePointer<UInt8>,
        imageWidth: Int,
        tileX: Int, tileY: Int,
        tileW: Int, tileH: Int,
        earlyExitThreshold: UInt64 = .max
    ) -> UInt64 {
        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var totalDiff: UInt64 = 0

        let simdStride = 16 // bytes per SIMD vector = 4 pixels
        let rowBytes = tileW * bytesPerPixel
        let simdChunks = rowBytes / simdStride
        let remainderStart = simdChunks * simdStride

        for y in tileY..<(tileY + tileH) {
            let rowBase = y * bytesPerRow + tileX * bytesPerPixel

            // --- SIMD path: 4 pixels (16 bytes) per iteration ---
            var chunkOffset = rowBase
            for _ in 0..<simdChunks {
                let cur = UnsafeRawPointer(currentPixels + chunkOffset)
                    .loadUnaligned(as: SIMD16<UInt8>.self)
                let prev = UnsafeRawPointer(previousPixels + chunkOffset)
                    .loadUnaligned(as: SIMD16<UInt8>.self)

                // Unsigned absolute difference per lane: max(a,b) - min(a,b)
                let maxVal = cur.replacing(with: prev, where: cur .< prev)
                let minVal = cur.replacing(with: prev, where: cur .> prev)
                let d = maxVal &- minVal

                // Sum BGR channels only (skip alpha at indices 3, 7, 11, 15).
                let p0 = UInt64(d[0]) &+ UInt64(d[1]) &+ UInt64(d[2])
                let p1 = UInt64(d[4]) &+ UInt64(d[5]) &+ UInt64(d[6])
                let p2 = UInt64(d[8]) &+ UInt64(d[9]) &+ UInt64(d[10])
                let p3 = UInt64(d[12]) &+ UInt64(d[13]) &+ UInt64(d[14])

                totalDiff &+= p0 &+ p1 &+ p2 &+ p3
                chunkOffset += simdStride
            }

            // --- Scalar remainder for pixels that don't fill a SIMD vector ---
            var offset = rowBase + remainderStart
            let rowEnd = rowBase + rowBytes
            while offset < rowEnd {
                let diffB = abs(Int(currentPixels[offset]) - Int(previousPixels[offset]))
                let diffG = abs(Int(currentPixels[offset + 1]) - Int(previousPixels[offset + 1]))
                let diffR = abs(Int(currentPixels[offset + 2]) - Int(previousPixels[offset + 2]))
                totalDiff &+= UInt64(diffB + diffG + diffR)
                offset += bytesPerPixel
            }

            // Early exit if we've already exceeded the threshold.
            if totalDiff > earlyExitThreshold {
                return totalDiff
            }
        }

        return totalDiff
    }

    /// Scalar reference implementation of tile diff (for testing/benchmarking).
    /// Returns the same raw BGR diff total as `tileDiffSIMD` but using a simple loop.
    func tileDiffScalar(
        currentPixels: UnsafeMutablePointer<UInt8>,
        previousPixels: UnsafeMutablePointer<UInt8>,
        imageWidth: Int,
        tileX: Int, tileY: Int,
        tileW: Int, tileH: Int
    ) -> UInt64 {
        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var totalDiff: UInt64 = 0

        for y in tileY..<(tileY + tileH) {
            let rowOffset = y * bytesPerRow + tileX * bytesPerPixel
            for x in 0..<tileW {
                let offset = rowOffset + x * bytesPerPixel
                let diffB = abs(Int(currentPixels[offset]) - Int(previousPixels[offset]))
                let diffG = abs(Int(currentPixels[offset + 1]) - Int(previousPixels[offset + 1]))
                let diffR = abs(Int(currentPixels[offset + 2]) - Int(previousPixels[offset + 2]))
                totalDiff += UInt64(diffB + diffG + diffR)
            }
        }

        return totalDiff
    }
}
