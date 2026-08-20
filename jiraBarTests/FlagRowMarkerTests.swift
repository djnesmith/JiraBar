import XCTest
import AppKit
@testable import jiraBar

/// The flag marker is an SF Symbol carrying its own colour, drawn inside a text attachment. Two
/// things could quietly go wrong there and neither would fail to compile: AppKit could repaint it in
/// the menu's label colour (the default for a template image), or the attachment could render
/// nothing at all. Both produce a row that simply has no visible flag, which no other test would
/// catch — so this one rasterises it and looks.
final class FlagRowMarkerTests: XCTestCase {

    /// The most opaque pixel of `image`, drawn at `side`x`side` into an offscreen bitmap.
    private func opaquePixel(of image: NSImage, side: Int = 32) -> NSColor? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var best: NSColor?
        var bestAlpha: CGFloat = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if pixel.alphaComponent > bestAlpha {
                    bestAlpha = pixel.alphaComponent
                    best = pixel
                }
            }
        }
        return bestAlpha > 0.5 ? best : nil
    }

    func testMarkerExists() {
        XCTAssertNotNil(AppDelegate.flagRowImage, "flag.fill must resolve on this OS")
    }

    /// A template image is repainted in the menu's label colour, which would make the flag
    /// indistinguishable from any other glyph on the row.
    func testMarkerIsNotATemplate() {
        XCTAssertEqual(AppDelegate.flagRowImage?.isTemplate, false)
    }

    func testMarkerDrawsRed() throws {
        let image = try XCTUnwrap(AppDelegate.flagRowImage)
        let pixel = try XCTUnwrap(opaquePixel(of: image), "the symbol drew nothing opaque at all")
        let rgb = try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
        // Measured: r=1.0 g=0.26 b=0.27 — systemRed, not the label colour a template would give.
        XCTAssertGreaterThan(rgb.redComponent, rgb.greenComponent + 0.3,
                             "red channel should dominate — got \(rgb)")
        XCTAssertGreaterThan(rgb.redComponent, rgb.blueComponent + 0.3,
                             "red channel should dominate — got \(rgb)")
    }

    // MARK: - appendImage

    func testAppendImageAddsOneSizedAttachment() throws {
        let image = try XCTUnwrap(AppDelegate.flagRowImage)
        let string = NSMutableAttributedString(string: "").appendImage(image)

        XCTAssertEqual(string.length, 1, "an attachment is a single character")

        var range = NSRange()
        let attachment = try XCTUnwrap(
            string.attribute(.attachment, at: 0, effectiveRange: &range) as? NSTextAttachment
        )
        XCTAssertNotNil(attachment.image, "an attachment with no image renders as a blank box")
        XCTAssertEqual(attachment.image?.size, NSSize(width: 12, height: 12))

        let baseline = string.attribute(.baselineOffset, at: 0, effectiveRange: &range) as? CGFloat
        XCTAssertEqual(baseline, -1.0, "sits with the text rather than riding above it")
    }

    /// The leading `#` icon and the trailing flag share one mechanism; only the leading one pads.
    func testOnlyTheLeadingIconAddsATrailingSpace() throws {
        let withIcon = NSMutableAttributedString(string: "").appendIcon(iconName: "hash")
        XCTAssertEqual(withIcon.string.count, 2, "attachment plus its separating space")
        XCTAssertTrue(withIcon.string.hasSuffix(" "))

        let image = try XCTUnwrap(AppDelegate.flagRowImage)
        let withImage = NSMutableAttributedString(string: "").appendImage(image)
        XCTAssertFalse(withImage.string.hasSuffix(" "), "a trailing marker ends the line")
    }
}
