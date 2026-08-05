import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

#if os(iOS)
struct MobileGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func mobileGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(MobileGlass(shape: shape, tint: tint, interactive: interactive))
    }
}
#endif

#if os(macOS)
struct FullScreenToolbarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

struct WindowControlPositioner: NSViewRepresentable {
    let x: CGFloat
    let y: CGFloat
    @Binding var controlsVisible: Bool

    func makeNSView(context: Context) -> PositioningView {
        PositioningView(x: x, y: y) { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
    }

    func updateNSView(_ nsView: PositioningView, context: Context) {
        nsView.onControlsVisible = { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
        nsView.positionControls()
    }

    final class PositioningView: NSView {
        let x: CGFloat
        let y: CGFloat
        weak var positionedWindow: NSWindow?
        var onControlsVisible: (Bool) -> Void
        private var originalOrigins = [NSWindow.ButtonType: NSPoint]()
        private var observers = [NSObjectProtocol]()

        init(
            x: CGFloat,
            y: CGFloat,
            onControlsVisible: @escaping (Bool) -> Void
        ) {
            self.x = x
            self.y = y
            self.onControlsVisible = onControlsVisible
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, positionedWindow !== window else { return }
            removeObservers()
            positionedWindow = window
            originalOrigins = [:]
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onControlsVisible(false)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.positionControls()
                    self.onControlsVisible(true)
                }
            ]
            DispatchQueue.main.async {
                self.positionControls()
                self.onControlsVisible(!window.styleMask.contains(.fullScreen))
            }
        }

        func positionControls() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(kind) else { continue }
                let origin = originalOrigins[kind] ?? button.frame.origin
                originalOrigins[kind] = origin
                button.setFrameOrigin(NSPoint(x: origin.x + x, y: origin.y + y))
            }
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        }

        deinit {
            removeObservers()
        }
    }
}

extension View {
    func macLiquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            MacLiquidGlass(
                shape: shape,
                tint: tint,
                interactive: interactive
            )
        )
    }

    @ViewBuilder
    func actionBarGlass() -> some View {
        macLiquidGlass(in: Capsule(), interactive: true)
    }
}

struct MacLiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else if let tint {
            content.background(tint.opacity(0.22), in: shape)
                .background(.regularMaterial, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
#endif
