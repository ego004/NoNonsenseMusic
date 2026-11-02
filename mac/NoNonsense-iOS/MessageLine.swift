import SwiftUI

/// What the player or the library has to say ("Couldn't play “…”", "Added to Gym", "Couldn't add to “Gym”: …"), as a glass
/// capsule above the player bar for a few seconds: the Mac shows the same two messages in the same place. Without it
/// every failure on the iPhone was silent (29 Oct audit).
struct MessageLine: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    /// How far above the bottom edge it floats: over the tab bar and the player, or over a sheet's controls.
    var lift: CGFloat = 150

    var body: some View {
        let problem = player.errorMessage
        let message = problem ?? library.message
        ZStack {
            if let message {
                Label(message, systemImage: problem != nil ? "exclamationmark.triangle.fill" : library.messageSymbol)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .compatGlass(in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, lift)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.3), value: message)
    }
}
