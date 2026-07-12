import SwiftUI

/// Reusable "scanning" backdrop: a horizontal binary stream behind a sniffing
/// Wega whose head bobs gently, with a comic-book thought bubble next to her
/// that cycles through randomized status thoughts.
struct SniffingScene: View {
    /// Caption shown below the scene; if nil the caption row is omitted.
    var caption: String? = nil
    /// Pool of thoughts the bubble cycles through. A random rotation is used.
    var thoughts: [String] = SniffingScene.defaultThoughts
    /// Wega sprite size in points.
    var wegaSize: CGFloat = 120
    /// Total scene height (binary lanes are drawn across this full area).
    var height: CGFloat = 170

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                BinaryStream()
                    .frame(height: height)

                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    WigglyWega(size: wegaSize)
                    ThoughtBubble(thoughts: thoughts)
                    Spacer(minLength: 0)
                }
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let defaultThoughts: [String] = [
        tr("Czy ten cask jest świeży?"),
        tr("Hmm… znajomy zapach"),
        tr("Coś tu pachnie aktualizacją"),
        tr("SHA256 się zgadza?"),
        tr("Czuję starą wersję…"),
        tr("Sniff sniff… Homebrew"),
        "0x4A 0x65 0x6C 0x6C 0x79",
        tr("Czy plist mówi prawdę?"),
        tr("Łapię trop wersji"),
        tr("Wąchanie /Applications…"),
        tr("Info.plist… mhm"),
        tr("Trop CFBundleShortVersion"),
        tr("Pachnie świeżym dmg"),
        tr("Ślad prowadzi do Cellar"),
        tr("Pulę pamięci czuć tu mocno"),
        tr("Czy to zapach Sparkle?"),
        tr("Mhm… kolejna wersja"),
    ]
}

/// Wega in the .sniff pose with a subtle continuous head-bob that reads as
/// active sniffing.
struct WigglyWega: View {
    var size: CGFloat = 120

    @State private var wiggle: Bool = false

    var body: some View {
        WegaFull(pose: .sniff, size: size)
            .rotationEffect(.degrees(wiggle ? 2.4 : -2.4), anchor: .bottom)
            .offset(y: wiggle ? -1 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true)) {
                    wiggle = true
                }
            }
    }
}

/// Comic-book thought cloud (a rounded "puff" with two trailing dots pointing
/// back toward Wega). Cycles through `thoughts` on a 2.5 s rotation with a
/// fade/scale transition.
struct ThoughtBubble: View {
    var thoughts: [String]
    var rotateInterval: TimeInterval = 2.5

    @State private var index: Int = 0
    @State private var visible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(thoughts.isEmpty ? "" : thoughts[index % max(thoughts.count, 1)])
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.wegaInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.wegaHoney)
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            )
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.85, anchor: .bottomLeading)

            HStack(spacing: 4) {
                Circle()
                    .fill(Color.wegaHoney)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(Color.wegaHoney)
                    .frame(width: 5, height: 5)
                Circle()
                    .fill(Color.wegaHoney)
                    .frame(width: 3, height: 3)
            }
            .padding(.leading, 6)
            .opacity(visible ? 1 : 0)
        }
        // Vertical only. `horizontal: true` pinned the bubble to its text's intrinsic width
        // and refused to be squeezed — one more element telling the layout "make room for
        // me", which (with the binary stream) pushed the detail column wide enough to shove
        // the sidebar off-screen during a scan. The thoughts are short, so nothing wraps in
        // practice; this just stops the bubble from dictating width.
        .fixedSize(horizontal: false, vertical: true)
        .task(id: thoughts.count) {
            guard thoughts.count > 1 else { return }
            // Start on a random thought so multiple screens don't sync up.
            index = Int.random(in: 0..<thoughts.count)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(rotateInterval))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.25)) { visible = false }
                try? await Task.sleep(for: .seconds(0.28))
                if Task.isCancelled { break }
                index = nextIndex(from: index, max: thoughts.count)
                withAnimation(.easeInOut(duration: 0.25)) { visible = true }
            }
        }
    }

    private func nextIndex(from current: Int, max: Int) -> Int {
        guard max > 1 else { return 0 }
        var next = Int.random(in: 0..<max)
        if next == current { next = (current + 1) % max }
        return next
    }
}
