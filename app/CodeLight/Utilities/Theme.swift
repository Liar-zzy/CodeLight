import SwiftUI

/// CodeLight design tokens. The brand is built around a single neon-lime
/// accent (#d7fe62) on near-black surfaces, in the spirit of modern AI/dev
/// tools (Vercel, Linear, Raycast). Use these tokens instead of system
/// colors so the app stays visually coherent and a future palette tweak is
/// a one-file change.
enum Theme {

    // MARK: - Brand
    /// Primary accent — used sparingly for active states, primary CTAs,
    /// connection indicators, and the focus rail.
    static let brand        = Color(red: 0xD7 / 255, green: 0xFE / 255, blue: 0x62 / 255)
    /// Translucent fill for subtle brand surfaces (active row tint, chip bg).
    static let brandSoft    = Color(red: 0xD7 / 255, green: 0xFE / 255, blue: 0x62 / 255).opacity(0.12)
    /// 40% brand — chevrons, secondary outlines, dim brand text.
    static let brandDim     = Color(red: 0xD7 / 255, green: 0xFE / 255, blue: 0x62 / 255).opacity(0.45)
    /// Foreground color to use ON a brand-filled surface (always near-black
    /// because lime+white has terrible contrast).
    static let onBrand      = Color(red: 0x07 / 255, green: 0x0A / 255, blue: 0x05 / 255)

    // MARK: - Surfaces
    /// Root background — near-pure black, slightly warm to feel less clinical.
    static let bgPrimary    = Color(red: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255)
    /// Cards / list rows.
    static let bgSurface    = Color(red: 0x12 / 255, green: 0x13 / 255, blue: 0x15 / 255)
    /// Raised surfaces (compose bar, chips, code blocks).
    static let bgElevated   = Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x1E / 255)

    // MARK: - Text
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.36)

    // MARK: - Lines
    static let divider       = Color.white.opacity(0.08)
    static let border        = Color.white.opacity(0.12)
    static let borderActive  = Color(red: 0xD7 / 255, green: 0xFE / 255, blue: 0x62 / 255).opacity(0.5)

    // MARK: - Status
    /// Success / active. Reuses brand so the eye lands on one color family.
    static let success       = Color(red: 0xD7 / 255, green: 0xFE / 255, blue: 0x62 / 255)
    static let warning       = Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x3C / 255)
    static let danger        = Color(red: 0xFF / 255, green: 0x55 / 255, blue: 0x5A / 255)
    static let info          = Color(red: 0x60 / 255, green: 0xA8 / 255, blue: 0xFF / 255)
}

// MARK: - View Helpers

extension View {
    /// Standard CodeLight card surface — bg + border + corner.
    func brandSurface(corner: CGFloat = 12) -> some View {
        self
            .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }

    /// Raised pill (chip / button background).
    func brandPill(active: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(active ? Theme.brandSoft : Theme.bgElevated)
            )
            .overlay(
                Capsule().stroke(active ? Theme.borderActive : Theme.border, lineWidth: 0.5)
            )
    }
}
