import Foundation
import Testing
@testable import CanopyMusicCore

@Suite struct ArtworkSizingTests {
    /// The sizes the apps draw art at land in the buckets the cache budgets were worked out for.
    @Test func bucketsRoundUpToTheDrawnPixels() {
        #expect(ArtworkSizing.bucket(points: 54, scale: 1) == 64)      // TV Up next row
        #expect(ArtworkSizing.bucket(points: 52, scale: 2) == 128)     // iPad Up next row
        #expect(ArtworkSizing.bucket(points: 64, scale: 1) == 64)      // exactly a bucket
        #expect(ArtworkSizing.bucket(points: 65, scale: 1) == 128)
        #expect(ArtworkSizing.bucket(points: 600, scale: 1) == 640)    // TV Now Playing
        #expect(ArtworkSizing.bucket(points: 300, scale: 1) == 384)    // TV Now Playing at its smallest
        #expect(ArtworkSizing.bucket(points: 450, scale: 2) == 1024)   // iPad Now Playing
        #expect(ArtworkSizing.bucket(points: 0, scale: 2) == 64)
        #expect(ArtworkSizing.bucket(points: -10, scale: 2) == 64)
        #expect(ArtworkSizing.bucket(points: 1024, scale: 0) == 1024)  // an unknown scale counts as 1
    }

    /// Nothing is decoded past the biggest bucket, however big it's drawn (a Mac window on a 6K display).
    @Test func bucketsAreCapped() {
        #expect(ArtworkSizing.bucket(points: 3000, scale: 2) == ArtworkSizing.buckets.last!)
        #expect(ArtworkSizing.buckets.last == 2048)
        #expect(ArtworkSizing.buckets == ArtworkSizing.buckets.sorted())
    }

    /// Square art decodes at the bucket; wide or tall art decodes so its shorter side reaches the
    /// bucket (the view crops it to a square); nothing is ever upsampled or decoded past the cap.
    @Test func thumbnailSideFillsTheSquare() {
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 64, width: 1200, height: 1200) == 64)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 64, width: 1200, height: 600) == 128)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 64, width: 600, height: 1200) == 128)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 64, width: 1000, height: 300) == 214)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 640, width: 600, height: 600) == 600)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 640, width: 160, height: 160) == 160)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 1024, width: 9000, height: 500) == 2048)
        #expect(ArtworkSizing.thumbnailMaxPixelSize(bucket: 64, width: 0, height: 0) == 64)
    }

    @Test func costIsFourBytesAPixel() {
        #expect(ArtworkSizing.cost(width: 64, height: 64) == 16_384)
        #expect(ArtworkSizing.cost(width: 1200, height: 1200) == 5_760_000)
        #expect(ArtworkSizing.cost(width: -1, height: 10) == 0)
    }

    /// The budgets hold a full party screen: the TV's Now Playing art and a column of rows, with
    /// room for the songs before and after; the blurred copies stay under their own small budget.
    @Test func budgetsFitTheScreens() {
        let tvNowPlaying = ArtworkSizing.cost(width: 640, height: 640)
        let tvRow = ArtworkSizing.cost(width: 64, height: 64)
        #expect(20 * tvNowPlaying + 100 * tvRow < ArtworkSizing.tvBudgetBytes)
        let padNowPlaying = ArtworkSizing.cost(width: 1024, height: 1024)
        let padRow = ArtworkSizing.cost(width: 128, height: 128)
        #expect(15 * padNowPlaying + 100 * padRow < ArtworkSizing.padBudgetBytes)
        #expect(80 * ArtworkSizing.cost(width: 64, height: 64) < ArtworkSizing.blurredBudgetBytes)
    }

    /// Album art decodes; a guest's absurd image (any URL goes through the hub) is skipped.
    @Test func verdicts() {
        #expect(ArtworkSizing.verdict(dataBytes: 180_000, width: 1200, height: 1200) == .decode)
        #expect(ArtworkSizing.verdict(dataBytes: 2_000_000, width: 3000, height: 3000) == .decode)
        #expect(ArtworkSizing.verdict(dataBytes: 5_000_000, width: 8000, height: 8000) == .decode)
        #expect(ArtworkSizing.verdict(dataBytes: 21 << 20, width: 1200, height: 1200) == .tooMuchData(bytes: 21 << 20))
        #expect(ArtworkSizing.verdict(dataBytes: 100_000, width: 10_001, height: 10) == .tooBig(width: 10_001, height: 10))
        #expect(ArtworkSizing.verdict(dataBytes: 100_000, width: 10, height: 20_000) == .tooBig(width: 10, height: 20_000))
        #expect(ArtworkSizing.verdict(dataBytes: ArtworkSizing.maxDataBytes, width: ArtworkSizing.maxSide, height: ArtworkSizing.maxSide) == .decode)
    }
}
