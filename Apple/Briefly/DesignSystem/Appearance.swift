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

#if os(macOS)
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? dark
            : light
        return NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#else
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(uiColor: UIColor { traits in
        let components = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#endif

private let appBackground = adaptiveColor(
    light: (0.957, 0.953, 0.941),
    dark: (0.018, 0.020, 0.030)
)

let sidebarBackground = adaptiveColor(
    light: (0.975, 0.973, 0.965),
    dark: (0.026, 0.028, 0.043)
)

let readerBackground = adaptiveColor(
    light: (0.986, 0.984, 0.976),
    dark: (0.022, 0.024, 0.038)
)
