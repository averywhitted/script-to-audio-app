import SwiftUI

// MARK: - Semantic color tokens
//
// All UI color decisions go through this file.  To change a color app-wide,
// update the value here — every call site picks it up automatically.
//
// Usage:  `.foregroundStyle(AppColors.destructive)`
//         `.background(AppColors.success.opacity(0.12))`
//
// The tokens map to adaptive system colors so they look correct in both
// light and dark mode without any extra work at the call site.

enum AppColors {

    // ── Affirmative / success ────────────────────────────────────────────────

    /// Rendered-badge dot, render-complete circle, engine-ready status strip.
    static let success: Color = .green

    /// Engine "ready to use" label in the Generate view status strip.
    static let engineReady: Color = .green

    // ── Warning / caution ────────────────────────────────────────────────────

    /// Engine "not ready / needs install" label in the Generate view status strip.
    static let engineNotReady: Color = .orange

    /// Parser low-confidence warning triangle (⚠).
    static let lowConfidence: Color = .orange

    /// "Update Available" toolbar badge.
    static let updateAvailable: Color = .orange

    // ── Destructive / danger ─────────────────────────────────────────────────

    /// Remove / Mark-as-noise buttons — any irreversible or potentially
    /// destructive action the user can undo via the corrections system.
    static let destructive: Color = .red

    /// "Report a Bug" toolbar button — distinct from generic destructive because
    /// it should stand out but isn't a data-modification action.
    static let bugReport: Color = .red

    // ── Feature-specific ─────────────────────────────────────────────────────

    /// "Make Simultaneous" multi-select action in ReviewView.
    static let simultaneous: Color = .purple
}

// MARK: - Convenience ShapeStyle helpers
//
// Use these for .background() calls that need a translucent tinted fill —
// the standard pattern is `color.opacity(0.10)` but having named helpers
// makes it easy to tweak the opacity value globally.

extension AppColors {

    /// Lightly tinted fill used behind pill/capsule labels (opacity ≈ 10 %).
    static func pillBackground(_ color: Color) -> Color {
        color.opacity(0.10)
    }

    /// Slightly stronger tint used for larger background fills (opacity ≈ 12 %).
    static func subtleFill(_ color: Color) -> Color {
        color.opacity(0.12)
    }
}
