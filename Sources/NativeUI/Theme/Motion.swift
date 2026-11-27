import SwiftUI

public enum NativeMotion {
    public enum Kind: Sendable { case quick, settle, glide }

    public static let settleSeconds = 0.24

    public static func animation(_ kind: Kind, reduceMotion: Bool) -> Animation? {
        switch kind {
        case .quick: .easeOut(duration: 0.12)
        case .settle: reduceMotion ? nil : .spring(.smooth(duration: settleSeconds))
        case .glide: reduceMotion ? nil : .smooth(duration: 0.4)
        }
    }

    public static func comingAndGoing(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .opacity.animation(animation(.settle, reduceMotion: false)), removal: .opacity.animation(nil))
    }
}

private struct NativeAnimation<V: Equatable>: ViewModifier {
    let kind: NativeMotion.Kind
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(NativeMotion.animation(kind, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    public func nativeAnimation<V: Equatable>(_ kind: NativeMotion.Kind, value: V) -> some View {
        modifier(NativeAnimation(kind: kind, value: value))
    }
}

@MainActor
public func withNativeAnimation<Result>(_ kind: NativeMotion.Kind, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(NativeMotion.animation(kind, reduceMotion: reduceMotion), body)
}
