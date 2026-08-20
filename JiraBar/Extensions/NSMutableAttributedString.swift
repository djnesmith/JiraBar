import Foundation
import SwiftUI		

extension NSMutableAttributedString {

    @discardableResult
    func appendString(string: String) -> NSMutableAttributedString {
        self.append(NSMutableAttributedString(string: string))
        
        return self
    }

    @discardableResult
    func appendString(string: String, color: String) -> NSMutableAttributedString {
        var attributes = [NSAttributedString.Key: AnyObject]()
        attributes[.foregroundColor] = NSColor(hex: color)
        self.append(NSMutableAttributedString(string: string, attributes: attributes))
        
        return self
    }
    
    /// `NSColor(hex:)` flattens to a fixed sRGB value, so dynamic system colours have to arrive as colours.
    @discardableResult
    func appendString(string: String, color: NSColor) -> NSMutableAttributedString {
        self.append(NSMutableAttributedString(string: string, attributes: [.foregroundColor: color]))
        return self
    }

    @discardableResult
    func appendIcon(iconName: String, color: NSColor = NSColor.gray) -> NSMutableAttributedString {
        appendImage(NSImage(named: iconName)?.tint(color: color))
        self.appendString(string: " ")

        return self
    }

    /// Appends an already-built image inline, sized and baselined to sit with the text.
    ///
    /// Split out of `appendIcon` so a caller that has an image rather than an asset name — an SF
    /// Symbol carrying its own colour, which `NSImage(named:)` cannot load — can use the same
    /// sizing and baseline. No trailing space: a trailing icon is the end of the line.
    @discardableResult
    func appendImage(_ image: NSImage?, size: CGFloat = 12) -> NSMutableAttributedString {
        image?.size = NSSize(width: size, height: size)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        attachment.image = image
        let imageString = NSMutableAttributedString(attachment: attachment)
        imageString.addAttribute(
            .baselineOffset,
            value: -1.0,
            range: NSMakeRange(0, imageString.length)
        )
        self.append(imageString)

        return self
    }

    @discardableResult
    func appendSeparator() -> NSMutableAttributedString {
        self.append(NSMutableAttributedString(string: "   "))
        return self
    }
    
    @discardableResult
    func appendNewLine() -> NSMutableAttributedString {
        self.append(NSMutableAttributedString(string: "\n"))
        return self
    }
                    
}
