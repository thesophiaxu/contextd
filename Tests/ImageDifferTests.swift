import XCTest
@testable import ContextD

/// Tests for ImageDiffer: verifies SIMD-optimized tile diff produces identical
/// results to the scalar reference implementation, and benchmarks both paths.
final class ImageDifferTests: XCTestCase {
    let differ = ImageDiffer()

    // MARK: - Helpers

    /// Allocate a BGRA pixel buffer of the given dimensions, filled with a value.
    private func makeBuffer(width: Int, height: Int, fill: UInt8 = 0) -> UnsafeMutablePointer<UInt8> {
        let count = width * height * 4
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buf.initialize(repeating: fill, count: count)
        return buf
    }

    /// Set a single pixel's BGRA values.
    private func setPixel(
        _ buf: UnsafeMutablePointer<UInt8>,
        width: Int,
        x: Int, y: Int,
        b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255
    ) {
        let offset = (y * width + x) * 4
        buf[offset] = b
        buf[offset + 1] = g
        buf[offset + 2] = r
        buf[offset + 3] = a
    }

    // MARK: - Correctness Tests

    /// Identical buffers should produce zero diff from both paths.
    func testIdenticalBuffers() {
        let w = 64, h = 64
        let a = makeBuffer(width: w, height: h, fill: 128)
        let b = makeBuffer(width: w, height: h, fill: 128)
        defer { a.deallocate(); b.deallocate() }

        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )

        XCTAssertEqual(scalar, 0, "Scalar diff of identical buffers should be 0")
        XCTAssertEqual(simd, 0, "SIMD diff of identical buffers should be 0")
    }

    /// Completely different buffers (0 vs 255) should produce the maximum diff.
    func testMaxDiff() {
        let w = 32, h = 32
        let a = makeBuffer(width: w, height: h, fill: 0)
        let b = makeBuffer(width: w, height: h, fill: 255)
        defer { a.deallocate(); b.deallocate() }

        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )

        // 32*32 pixels * 3 channels * 255 diff = 783,360
        let expected: UInt64 = 32 * 32 * 3 * 255
        XCTAssertEqual(scalar, expected, "Scalar max diff mismatch")
        XCTAssertEqual(simd, expected, "SIMD max diff mismatch")
    }

    /// Alpha channel should be ignored by both paths.
    func testAlphaIgnored() {
        let w = 32, h = 32
        let a = makeBuffer(width: w, height: h, fill: 0)
        let b = makeBuffer(width: w, height: h, fill: 0)
        defer { a.deallocate(); b.deallocate() }

        // Set only alpha channel to differ
        for y in 0..<h {
            for x in 0..<w {
                let offset = (y * w + x) * 4 + 3 // alpha byte
                b[offset] = 255
            }
        }

        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )

        XCTAssertEqual(scalar, 0, "Scalar should ignore alpha")
        XCTAssertEqual(simd, 0, "SIMD should ignore alpha")
    }

    /// Single pixel change should be detected correctly.
    func testSinglePixelChange() {
        let w = 32, h = 32
        let a = makeBuffer(width: w, height: h, fill: 0)
        let b = makeBuffer(width: w, height: h, fill: 0)
        defer { a.deallocate(); b.deallocate() }

        // Change one pixel: B=10, G=20, R=30
        setPixel(b, width: w, x: 5, y: 5, b: 10, g: 20, r: 30)

        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 32, tileH: 32
        )

        XCTAssertEqual(scalar, 60, "Scalar: 10+20+30 = 60")
        XCTAssertEqual(simd, 60, "SIMD: 10+20+30 = 60")
    }

    /// Test with a tile offset (not at origin) in a larger image.
    func testTileOffset() {
        let w = 128, h = 128
        let a = makeBuffer(width: w, height: h, fill: 100)
        let b = makeBuffer(width: w, height: h, fill: 100)
        defer { a.deallocate(); b.deallocate() }

        // Change pixels in a tile at offset (32, 32) with size 32x32
        for y in 32..<64 {
            for x in 32..<64 {
                setPixel(b, width: w, x: x, y: y, b: 200, g: 200, r: 200)
            }
        }

        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 32, tileY: 32, tileW: 32, tileH: 32
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 32, tileY: 32, tileW: 32, tileH: 32
        )

        XCTAssertEqual(scalar, simd, "Offset tile: scalar and SIMD must agree")
        // Each pixel: |200-100| * 3 channels = 300. 32*32 pixels = 1024. Total = 307,200
        XCTAssertEqual(scalar, 32 * 32 * 300, "Expected diff for uniform 100->200 change")
    }

    /// Non-power-of-two tile width (triggers scalar remainder path).
    func testNonAlignedTileWidth() {
        let w = 64, h = 64
        let a = makeBuffer(width: w, height: h, fill: 50)
        let b = makeBuffer(width: w, height: h, fill: 100)
        defer { a.deallocate(); b.deallocate() }

        // Use tile width of 7 (not divisible by 4) to exercise scalar remainder
        let scalar = differ.tileDiffScalar(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 7, tileH: 5
        )
        let simd = differ.tileDiffSIMD(
            currentPixels: a, previousPixels: b,
            imageWidth: w, tileX: 0, tileY: 0, tileW: 7, tileH: 5
        )

        XCTAssertEqual(scalar, simd, "Non-aligned tile: scalar and SIMD must agree")
        // 7*5 = 35 pixels, each channel diff = 50, 3 channels = 150 per pixel
        XCTAssertEqual(scalar, 35 * 150, "Expected diff for 7x5 tile")
    }

    /// Random data: SIMD must match scalar for random pixel values.
    func testRandomData() {
        let w = 128, h = 128
        let a = makeBuffer(width: w, height: h)
        let b = makeBuffer(width: w, height: h)
        defer { a.deallocate(); b.deallocate() }

        // Fill with pseudo-random data
        let count = w * h * 4
        for i in 0..<count {
            a[i] = UInt8(truncatingIfNeeded: (i &* 7 &+ 13) ^ (i >> 3))
            b[i] = UInt8(truncatingIfNeeded: (i &* 11 &+ 37) ^ (i >> 2))
        }

        // Test multiple tile sizes and offsets
        let testCases: [(tx: Int, ty: Int, tw: Int, th: Int)] = [
            (0, 0, 32, 32),
            (16, 16, 32, 32),
            (0, 0, 7, 13),
            (3, 5, 17, 11),
            (0, 0, 1, 1),
            (0, 0, 128, 128),
        ]

        for tc in testCases {
            let scalar = differ.tileDiffScalar(
                currentPixels: a, previousPixels: b,
                imageWidth: w, tileX: tc.tx, tileY: tc.ty, tileW: tc.tw, tileH: tc.th
            )
            let simd = differ.tileDiffSIMD(
                currentPixels: a, previousPixels: b,
                imageWidth: w, tileX: tc.tx, tileY: tc.ty, tileW: tc.tw, tileH: tc.th
            )

            XCTAssertEqual(scalar, simd,
                "Random data mismatch at tile (\(tc.tx),\(tc.ty)) \(tc.tw)x\(tc.th): scalar=\(scalar) simd=\(simd)")
        }
    }

    // MARK: - Benchmarks

    /// Benchmark the scalar path on a realistic workload.
    func testBenchmarkScalar() {
        let w = 2560, h = 1440
        let a = makeBuffer(width: w, height: h, fill: 100)
        let b = makeBuffer(width: w, height: h, fill: 110)
        defer { a.deallocate(); b.deallocate() }

        // Simulate diffing all 32x32 tiles across a full display
        let tileSize = 32
        let cols = (w + tileSize - 1) / tileSize
        let rows = (h + tileSize - 1) / tileSize

        measure {
            for row in 0..<rows {
                for col in 0..<cols {
                    let tileX = col * tileSize
                    let tileY = row * tileSize
                    let tileW = min(tileSize, w - tileX)
                    let tileH = min(tileSize, h - tileY)
                    _ = differ.tileDiffScalar(
                        currentPixels: a, previousPixels: b,
                        imageWidth: w,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH
                    )
                }
            }
        }
    }

    /// Benchmark the SIMD path on the same workload.
    func testBenchmarkSIMD() {
        let w = 2560, h = 1440
        let a = makeBuffer(width: w, height: h, fill: 100)
        let b = makeBuffer(width: w, height: h, fill: 110)
        defer { a.deallocate(); b.deallocate() }

        let tileSize = 32
        let cols = (w + tileSize - 1) / tileSize
        let rows = (h + tileSize - 1) / tileSize

        measure {
            for row in 0..<rows {
                for col in 0..<cols {
                    let tileX = col * tileSize
                    let tileY = row * tileSize
                    let tileW = min(tileSize, w - tileX)
                    let tileH = min(tileSize, h - tileY)
                    _ = differ.tileDiffSIMD(
                        currentPixels: a, previousPixels: b,
                        imageWidth: w,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH
                    )
                }
            }
        }
    }

    /// Benchmark SIMD with early exit (simulates realistic threshold behavior).
    func testBenchmarkSIMDEarlyExit() {
        let w = 2560, h = 1440
        let a = makeBuffer(width: w, height: h, fill: 0)
        let b = makeBuffer(width: w, height: h, fill: 255)
        defer { a.deallocate(); b.deallocate() }

        let tileSize = 32
        let cols = (w + tileSize - 1) / tileSize
        let rows = (h + tileSize - 1) / tileSize
        // Threshold that will be exceeded after ~1 row of a tile
        let threshold: UInt64 = 32 * 3 * 128

        measure {
            for row in 0..<rows {
                for col in 0..<cols {
                    let tileX = col * tileSize
                    let tileY = row * tileSize
                    let tileW = min(tileSize, w - tileX)
                    let tileH = min(tileSize, h - tileY)
                    _ = differ.tileDiffSIMD(
                        currentPixels: a, previousPixels: b,
                        imageWidth: w,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        earlyExitThreshold: threshold
                    )
                }
            }
        }
    }
}
