import AppKit

/// Custom NSView used as an `NSMenuItem.view` so a PR row can respond to both left- and right-click.
/// Left-click opens the PR URL; right-click copies it. The view paints its own highlight when
/// hovered to mimic the standard menu-item look.
final class PRMenuItemView: NSView {
    private let attributedTitle: NSAttributedString
    private let icon: NSImage?
    /// Modifier flags (⌘/⌥/⌃) are passed through so callers can route to the PR itself
    /// (no modifier), the repo homepage (⌃), the Actions tab (⌥), or Create Release (⌘).
    private let onLeftClick: (NSEvent.ModifierFlags) -> Void
    private let onRightClick: () -> Void

    private let leftInset: CGFloat = 14
    private let rightInset: CGFloat = 14
    private let iconSize: CGFloat = 16
    private let iconTextSpacing: CGFloat = 6
    private let verticalInset: CGFloat = 4

    private var isHighlighted = false
    /// Modifier flags currently held while the cursor is over this row. Drives the hint
    /// overlay — the pill that says "Left Click to …" so the user learns what each modifier
    /// does without leaving the menu. Only sampled while `pollTimer` is running.
    private var hoverModifiers: NSEvent.ModifierFlags = []
    /// Polls `NSEvent.modifierFlags` while the mouse is over the row. `.flagsChanged` events
    /// aren't reliably dispatched inside NSMenu's modal tracking loop, so a short-interval
    /// poll is the only way to notice a key press while the cursor is stationary.
    private var pollTimer: Timer?

    init(
        attributedTitle: NSAttributedString,
        icon: NSImage?,
        width: CGFloat = 360,
        onLeftClick: @escaping (NSEvent.ModifierFlags) -> Void,
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
        hoverModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        startModifierPolling()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        hoverModifiers = []
        stopModifierPolling()
        needsDisplay = true
    }

    /// The tracking area doesn't fire mouseExited when the menu closes — the view leaves the
    /// window instead. Reset the highlight both when the view attaches to a window (menu opens)
    /// and when it detaches, so the next open starts clean.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHighlighted = false
        hoverModifiers = []
        stopModifierPolling()
        needsDisplay = true
    }

    deinit {
        stopModifierPolling()
    }

    /// Sample the global modifier state every 50ms while the mouse is over the row. Explicitly
    /// added to `.eventTracking` mode so the timer keeps firing during NSMenu's modal loop —
    /// `.common` alone would let it stall while a menu is open.
    private func startModifierPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.hoverModifiers != mods {
                self.hoverModifiers = mods
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        pollTimer = timer
    }

    private func stopModifierPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Left-side hint: "Left Click to …" varying by the currently-held modifier. Nil when no
    /// modifier is held so the plain left-click-opens-the-PR case doesn't need an explainer.
    private var leftHintText: String? {
        guard isHighlighted else { return nil }
        if hoverModifiers.contains(.shift)   { return "Left Click to Copy PR #" }
        if hoverModifiers.contains(.command) { return "Left Click to Create Release" }
        if hoverModifiers.contains(.option)  { return "Left Click to open Actions" }
        if hoverModifiers.contains(.control) { return "Left Click to open Repo" }
        return nil
    }

    /// Right-side hint — the right-click affordance is only shown as a companion to the
    /// modifier hint, not on plain hover, so casual mouse-over doesn't clutter every row.
    private var rightHintText: String? {
        guard leftHintText != nil else { return nil }
        return "Right Click Copy URL"
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        enclosingMenuItem?.menu?.cancelTracking()
        onLeftClick(modifiers)
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

        if let hint = leftHintText {
            drawHintPill(hint, alignment: .left)
        }
        if let hint = rightHintText {
            drawHintPill(hint, alignment: .right)
        }
    }

    private enum HintAlignment { case left, right }

    /// Draws a small pill over the row explaining a click action. Aligned to the requested
    /// side, vertically centered, using the system accent color so it reads on both light
    /// and dark themes.
    private func drawHintPill(_ text: String, alignment: HintAlignment) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let padH: CGFloat = 8
        let padV: CGFloat = 2
        let pillWidth = ceil(textSize.width + padH * 2)
        let pillHeight = ceil(textSize.height + padV * 2)
        // Left pill starts just inside the row's left edge (past the icon column) so it doesn't
        // sit on the leading padding; right pill hugs the right inset. Both are vertically centered.
        let x: CGFloat
        switch alignment {
        case .left:  x = leftInset + iconSize + iconTextSpacing
        case .right: x = bounds.width - rightInset - pillWidth
        }
        let y = (bounds.height - pillHeight) / 2
        let pillRect = NSRect(x: x, y: y, width: pillWidth, height: pillHeight)

        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()

        attributed.draw(at: NSPoint(x: x + padH, y: y + padV))
    }
}
