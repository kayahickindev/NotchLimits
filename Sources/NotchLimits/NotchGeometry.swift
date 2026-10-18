import AppKit

/// Describes the physical notch band on a screen and the interaction zone
/// used by `HoverEngine` to decide when the cursor is "under the notch".
///
/// All rects are in AppKit's global screen coordinate space — origin at the
/// bottom-left of the primary display, Y increasing upward. This is the same
/// space `NSEvent.mouseLocation` and `NSScreen.frame` report in, so no
/// flipping is required anywhere this struct is consumed.
struct NotchGeometry {
    let screen: NSScreen
    /// The physical notch band, global coords: spans the camera housing.
    let notchRect: NSRect
    /// notchRect inset -12pt horizontally, extending 60pt past the screen's
    /// top edge down to 5pt below the menu bar's bottom edge — the dwell-
    /// tracking hit zone for `.idle`. Deliberately tight: the old 24pt/14pt
    /// slop overlapped browser-tab territory, so ordinary mousing near the
    /// top center kept setting off the peek.
    let hoverZone: NSRect
    /// Horizontal center of the notch band — the panel's fixed X anchor.
    let panelAnchorX: CGFloat
    /// Global Y of the menu bar's bottom edge on this screen.
    let menuBarBottomY: CGFloat

    /// Tallest open panel this screen can host: full screen height minus a
    /// 200pt bottom margin, never below the original 560 design height.
    /// Content past this scrolls (see PanelContent.maxListHeight) — the
    /// account list is viewport-bounded, never truncated.
    var maxOpenPanelHeight: CGFloat {
        max(560, screen.frame.height - 200)
    }

    /// Everything the window frame and the morph shape derive from. A change
    /// here (lid closed, monitor plugged in, resolution or arrangement
    /// changed) means the overlay has to move.
    struct Layout: Equatable {
        let screenFrame: NSRect
        let notchRect: NSRect
    }

    var layout: Layout {
        Layout(screenFrame: screen.frame, notchRect: notchRect)
    }

    /// Width of the synthetic band on a notchless screen: the 14" MacBook
    /// Pro's measured notch (663..848pt), so the pill looks the same on an
    /// external monitor as it does on the built-in display.
    static let syntheticNotchWidth: CGFloat = 185

    /// Picks the screen that actually has a notch (`safeAreaInsets.top > 0`)
    /// and derives the notch band from its auxiliary safe areas. Falls back
    /// to a synthetic centered band on the menu bar screen so the app still
    /// works on non-notched / clamshell setups.
    static func detect() -> NotchGeometry? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let insetTop = notched.safeAreaInsets.top
            let leftX = notched.auxiliaryTopLeftArea?.maxX ?? (notched.frame.midX - 100)
            let rightX = notched.auxiliaryTopRightArea?.minX ?? (notched.frame.midX + 100)
            let menuBarBottomY = notched.frame.maxY - insetTop
            let notchRect = NSRect(x: leftX, y: menuBarBottomY, width: max(rightX - leftX, 0), height: insetTop)
            return make(screen: notched, notchRect: notchRect, menuBarBottomY: menuBarBottomY)
        }
        // No physical notch (clamshell on an external monitor, or a notchless
        // Mac): a notch-sized band centered at the top of the menu bar
        // screen, using the real menu bar height so the hover zone still
        // sits right under it. screens.first is the screen holding the menu
        // bar; NSScreen.main follows the key window, which this accessory
        // app never owns.
        guard let primary = NSScreen.screens.first ?? NSScreen.main else { return nil }
        let menuBarHeight = max(primary.frame.maxY - primary.visibleFrame.maxY, 24)
        let width = syntheticNotchWidth
        let menuBarBottomY = primary.frame.maxY - menuBarHeight
        let notchRect = NSRect(x: primary.frame.midX - width / 2, y: menuBarBottomY, width: width, height: menuBarHeight)
        return make(screen: primary, notchRect: notchRect, menuBarBottomY: menuBarBottomY)
    }

    private static func make(screen: NSScreen, notchRect: NSRect, menuBarBottomY: CGFloat) -> NotchGeometry {
        let hoverZone = NSRect(
            x: notchRect.minX - 12,
            y: menuBarBottomY - 5,
            width: notchRect.width + 24,
            // +60 past screen.frame.maxY: macOS pins NSEvent.mouseLocation.y
            // at EXACTLY frame.maxY when the cursor is pushed to the top,
            // and NSRect.contains() excludes the max edge — a zone whose
            // top sat exactly at maxY rejected the cursor right when it was
            // shoved into the notch. Extending past it keeps that pinned
            // value strictly inside.
            height: (screen.frame.maxY + 60) - (menuBarBottomY - 5)
        )
        return NotchGeometry(
            screen: screen,
            notchRect: notchRect,
            hoverZone: hoverZone,
            panelAnchorX: notchRect.midX,
            menuBarBottomY: menuBarBottomY
        )
    }
}
