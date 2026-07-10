import AppKit

/// Custom NSView used as an `NSMenuItem.view` so a PR row can respond to both left- and right-click.
/// Left-click opens the PR URL; right-click copies it. The view paints its own highlight when
/// hovered to mimic the standard menu-item look.
final class PRMenuItemView: NSView {
    private let attributedTitle: NSAttributedString
    private let icon: NSImage?
    private let onLeftClick: () -> Void
    private let onRightClick: () -> Void

    private let leftInset: CGFloat = 14
    private let rightInset: CGFloat = 14
    private let iconSize: CGFloat = 16
    private let iconTextSpacing: CGFloat = 6
    private let verticalInset: CGFloat = 4

    private var isHighlighted = false

    init(
        attributedTitle: NSAttributedString,
        icon: NSImage?,
        width: CGFloat = 360,
        onLeftClick: @escaping () -> Void,
        onRightClick: @escaping () -> Void
    ) {
        self.attributedTitle = attributedTitle
        self.icon = icon
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick

        let textWidth = width - (leftInset + (icon != nil ? iconSize + iconTextSpacing : 0) + rightInset)
        let textBox = attributedTitle.boundingRect(
            with: NSSize(width: textWidth, height: 1000),
            options: [.usesLineFragmentOrigin]
        )
        let contentHeight = max(textBox.height, icon != nil ? iconSize : 0)
        let height = ceil(contentHeight + verticalInset * 2)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Menus run in a modal tracking loop where `.activeInActiveApp` never fires; `.activeAlways`
    /// is required so the tracking area is live while the menu is open.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    /// The tracking area doesn't fire mouseExited when the menu closes — the view leaves the
    /// window instead. Reset the highlight both when the view attaches to a window (menu opens)
    /// and when it detaches, so the next open starts clean.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
        enclosingMenuItem?.menu?.cancelTracking()
        onLeftClick()
    }

    override func rightMouseUp(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
        enclosingMenuItem?.menu?.cancelTracking()
        onRightClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
        }

        let iconX = leftInset
        if let icon {
            // Tint the symbol to the menu's text color so it reads on light + dark backgrounds.
            let tintColor = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            let tinted = icon.tint(color: tintColor)
            let rect = NSRect(
                x: iconX,
                y: (bounds.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        let textX = iconX + (icon != nil ? iconSize + iconTextSpacing : 0)
        let textRect = NSRect(
            x: textX,
            y: verticalInset,
            width: bounds.width - textX - rightInset,
            height: bounds.height - verticalInset * 2
        )

        // The attributed string's first line (PR title) has no explicit color attribute, which
        // renders as pure black — invisible in dark mode. Fill any uncolored ranges with the
        // system label color so the title adapts. Highlighted state recolors everything white.
        let mutable = NSMutableAttributedString(attributedString: attributedTitle)
        let full = NSRange(location: 0, length: mutable.length)
        if isHighlighted {
            mutable.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: full)
        } else {
            mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                if value == nil {
                    mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }
        }
        mutable.draw(with: textRect, options: [.usesLineFragmentOrigin])
    }
}
