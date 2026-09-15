import Foundation
import AppKit

extension NSImage {
    /// `.sourceIn`, not `.sourceAtop`: atop blends the colour into the artwork, so a colour carrying
    /// alpha — every semantic label colour does — is flattened against the glyph and baked opaque.
    /// `secondaryLabelColor` came out solid black in light mode that way. `.sourceIn` keeps the colour's
    /// own alpha, so a tinted glyph composites on the menu glass exactly as the text beside it does.
    func tint(color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()

        color.set()

        let imageRect = NSRect(origin: NSZeroPoint, size: image.size)
        imageRect.fill(using: .sourceIn)

        image.unlockFocus()

        return image
    }
    
    static func imageFromUrl(fromURL url: URL) -> NSImage? {
        guard let data = try? Foundation.Data(contentsOf: url) else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        return image
    }
}
