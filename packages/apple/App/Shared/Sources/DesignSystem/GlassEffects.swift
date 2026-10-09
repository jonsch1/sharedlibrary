import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Pins a header above scrolling content without a backing panel. Content scrolling
    /// underneath fades out through the system's soft scroll edge (a material fade before
    /// iOS/macOS 26).
    func fadingHeaderBar<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        modifier(FadingHeaderBar(header: header()))
    }

    /// A soft fade behind a bar for content the system scroll edge can't reach,
    /// such as an AppKit text view.
    func fadingBarBackground(_ edge: VerticalEdge = .top) -> some View {
        background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: edge == .top ? .top : .bottom,
                        endPoint: edge == .top ? .bottom : .top
                    )
                )
                .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        }
    }
}

extension View {
    /// Fades scrolling content out at its top and bottom edges so it never meets a header
    /// or bottom bar with a hard cut. Used for UIKit/AppKit text views, which the system
    /// scroll edge effect doesn't reach. Hit testing is unaffected.
    func scrollContentEdgeFade(top: CGFloat = 44, bottom: CGFloat = 32) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        }
    }
}

private struct FadingHeaderBar<Header: View>: ViewModifier {
    let header: Header

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            materialFade(content)
        }
        #else
        // The macOS scroll edge effect doesn't reach content in this borderless,
        // full-height window, so draw the blur fade directly.
        materialFade(content)
        #endif
    }

    private func materialFade(_ content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            header.fadingBarBackground()
        }
    }
}

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
                // Glass sits behind the content so solid fills inside a bar
                // (such as a selected ChoiceChip) keep full contrast instead of
                // being rendered with glass vibrancy.
                content.background {
                    Color.clear.glassEffect(glass, in: shape)
                }
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
        macLiquidGlass(in: Rectangle(), interactive: true)
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
