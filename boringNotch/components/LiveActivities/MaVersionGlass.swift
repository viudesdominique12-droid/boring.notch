//
//  MaVersionGlass.swift
//  boringNotch — ma-version
//
//  Native Liquid Glass (AppKit NSGlassEffectView, public API) behind the
//  open notch. Chosen by the user side by side against SwiftUI's
//  .glassEffect and tuned private variants: the plain system view is the one
//  that looks like Control Center.
//
//  The glass is a rounded rectangle whose top edge is pushed above the
//  window, so only the bottom corners show and the top stays flush with the
//  screen edge. It's inset horizontally to the notch body (the shape's top
//  "ears" stay transparent).
//

import AppKit
import SwiftUI

struct NativeGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var horizontalInset: CGFloat
    var tint: Double
    /// Album colour while music plays (soft glow through the glass).
    var glow: NSColor? = nil

    func makeNSView(context: Context) -> NativeGlassContainer {
        NativeGlassContainer()
    }

    func updateNSView(_ view: NativeGlassContainer, context: Context) {
        view.configure(cornerRadius: cornerRadius, horizontalInset: horizontalInset, tint: tint, glow: glow)
    }
}

final class NativeGlassContainer: NSView {
    private let glass: NSView
    private var cornerRadius: CGFloat = 24
    private var horizontalInset: CGFloat = 0

    init() {
        if #available(macOS 26.0, *) {
            glass = NSGlassEffectView()
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            glass = fallback
        }
        super.init(frame: .zero)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { nil }

    // Purely decorative: never steal clicks or scrolls from the notch content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cornerRadius: CGFloat, horizontalInset: CGFloat, tint: Double, glow: NSColor?) {
        self.cornerRadius = cornerRadius
        self.horizontalInset = horizontalInset
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            if let glow {
                glass.tintColor = glow.withAlphaComponent(0.32)
            } else {
                glass.tintColor = tint > 0.02 ? NSColor.black.withAlphaComponent(tint) : nil
            }
        } else {
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.masksToBounds = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // AppKit coordinates (y up): grow the glass above our top edge by the
        // corner radius so its top corners fall outside the window.
        glass.frame = NSRect(
            x: horizontalInset,
            y: 0,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: bounds.height + cornerRadius
        )
    }
}
