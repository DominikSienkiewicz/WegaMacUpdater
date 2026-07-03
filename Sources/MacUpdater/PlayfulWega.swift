import SwiftUI

/// A `WegaFull` that rests in `restPose` and, on a randomized cadence, performs
/// one of several playful "tricks" — a tail wag, a hop, a curious head-tilt, a
/// stretch, a shake-off or a full spin — before settling back to rest.
///
/// Changing the underlying pose animates Wega's ears and expression for free
/// (see `WegaHead.onChange(of:)`), while transient transforms move the whole
/// body. Used on calm empty states (e.g. "everything up to date") so a napping
/// Wega still feels alive: she dozes, occasionally stirs to pull a trick, then
/// dozes off again.
struct PlayfulWega: View {
    /// Pose Wega returns to between tricks. `.sleep` reads as a dozing dog.
    let restPose: WegaPose
    /// Sprite size in points.
    let size: CGFloat

    @State private var pose: WegaPose
    @State private var rotation: Double  = 0
    @State private var offsetX:  CGFloat = 0
    @State private var offsetY:  CGFloat = 0
    @State private var scaleX:   CGFloat = 1
    @State private var scaleY:   CGFloat = 1

    init(restPose: WegaPose = .idle, size: CGFloat = 170) {
        self.restPose = restPose
        self.size = size
        _pose = State(initialValue: restPose)
    }

    /// The repertoire of tricks Wega can pull.
    enum Trick: CaseIterable { case wag, hop, tilt, stretch, shake, spin }

    var body: some View {
        WegaFull(pose: pose, size: size)
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .offset(x: offsetX, y: offsetY)
            .task { await playLoop() }
    }

    // MARK: - Loop

    private func playLoop() async {
        // Stagger the start so multiple on-screen Wegas don't move in lockstep.
        try? await Task.sleep(for: .seconds(Double.random(in: 0.6...2.4)))
        var last: Trick? = nil
        let all = Trick.allCases
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3.0...6.5)))
            if Task.isCancelled { return }
            var next = all.randomElement() ?? .wag
            if next == last, all.count > 1 {
                next = all.filter { $0 != last }.randomElement() ?? next
            }
            last = next
            await perform(next)
        }
    }

    // MARK: - Trick execution

    private func perform(_ trick: Trick) async {
        switch trick {
        case .wag:     await wag()
        case .hop:     await hop()
        case .tilt:    await tilt()
        case .stretch: await stretch()
        case .shake:   await shake()
        case .spin:    await spin()
        }
    }

    /// Wake Wega into an expressive pose for the duration of a trick.
    private func wake(_ p: WegaPose) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pose = p }
    }

    /// Return to rest and zero every transform.
    private func settle() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            pose = restPose
            rotation = 0; offsetX = 0; offsetY = 0; scaleX = 1; scaleY = 1
        }
    }

    private func wag() async {
        wake(.happy)
        for _ in 0..<3 {
            withAnimation(.easeInOut(duration: 0.17)) { rotation = 3.5 }
            try? await Task.sleep(for: .seconds(0.17))
            withAnimation(.easeInOut(duration: 0.17)) { rotation = -3.5 }
            try? await Task.sleep(for: .seconds(0.17))
        }
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func hop() async {
        wake(.alert)
        for _ in 0..<2 {
            withAnimation(.easeOut(duration: 0.16)) { offsetY = -size * 0.15; scaleY = 1.04 }
            try? await Task.sleep(for: .seconds(0.16))
            withAnimation(.easeIn(duration: 0.15)) { offsetY = 0; scaleY = 0.93 }
            try? await Task.sleep(for: .seconds(0.15))
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { scaleY = 1 }
            try? await Task.sleep(for: .seconds(0.14))
        }
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func tilt() async {
        wake(.sniff)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { rotation = 8 }
        try? await Task.sleep(for: .seconds(0.85))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { rotation = -6 }
        try? await Task.sleep(for: .seconds(0.85))
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func stretch() async {
        wake(.idle)
        withAnimation(.easeInOut(duration: 0.5)) { scaleY = 1.09; scaleX = 0.95; offsetY = -size * 0.03 }
        try? await Task.sleep(for: .seconds(0.55))
        withAnimation(.easeInOut(duration: 0.35)) { scaleY = 0.95; scaleX = 1.04; offsetY = 0 }
        try? await Task.sleep(for: .seconds(0.4))
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func shake() async {
        wake(.idle)
        for i in 0..<6 {
            let dir: CGFloat = i.isMultiple(of: 2) ? 1 : -1
            withAnimation(.easeInOut(duration: 0.07)) { offsetX = dir * 4; rotation = Double(dir) * 2 }
            try? await Task.sleep(for: .seconds(0.07))
        }
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func spin() async {
        wake(.happy)
        withAnimation(.easeInOut(duration: 0.7)) { rotation = 360 }
        try? await Task.sleep(for: .seconds(0.72))
        rotation = 0            // 360° == 0° visually; reset without unwinding
        settle()
        try? await Task.sleep(for: .seconds(0.5))
    }
}
