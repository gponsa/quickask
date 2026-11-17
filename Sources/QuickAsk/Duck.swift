import AppKit
import Combine
import SwiftUI

// The pixel duck that lives on top of the popup.
//
// It's drawn in its own small, transparent, click-through window that sits on the
// popup's top edge. Keeping it separate means the popup's layout and shadow never
// change while the duck moves around.

/// The sprite frames, loaded once from QuickAsk.app/Contents/Resources/Duck/.
/// They were cut out of Art/duck-mockup.png by Art/tools/extract_duck.py.
enum DuckSprites {
    enum Anim: String, CaseIterable { case idle, run, jump, fall }

    /// Frames are drawn at half their pixel size, so on a Retina screen each image
    /// pixel is exactly one screen pixel (crisp, no blur).
    static let frames: [Anim: [NSImage]] = {
        var result: [Anim: [NSImage]] = [:]
        for anim in Anim.allCases {
            var list: [NSImage] = []
            var i = 0
            while let url = Bundle.main.url(forResource: "\(anim.rawValue)_\(i)", withExtension: "png", subdirectory: "Duck"),
                  let image = NSImage(contentsOf: url),
                  let rep = image.representations.first {
                image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
                list.append(image)
                i += 1
            }
            result[anim] = list
        }
        return result
    }()

    static var isAvailable: Bool { Anim.allCases.allSatisfy { !(frames[$0]?.isEmpty ?? true) } }
    static var cellSize: CGSize { frames[.idle]?.first?.size ?? CGSize(width: 53, height: 68) }
    /// Transparent rows below the feet in each frame (6 px in the source = 3 pt).
    static let footPadding: CGFloat = 3
}

/// Decides what the duck does, frame by frame (a tiny state machine driven by a timer).
@MainActor
final class DuckController: ObservableObject {
    @Published private(set) var frame: NSImage?
    @Published private(set) var x: CGFloat = 0           // left edge of the duck, in points
    @Published private(set) var y: CGFloat = 0           // 0 = standing on the bar, negative = in the air
    @Published private(set) var facingLeft = false

    private enum Action {
        case idle(until: TimeInterval)
        case run(to: CGFloat)
        case jump(dx: CGFloat)
        case fall
        case land
    }

    private var action: Action = .idle(until: 0)
    private var queue: [Action] = []                      // actions to play next (e.g. a series of hops)
    private var actionTime: TimeInterval = 0              // seconds since the current action started
    private var clock: TimeInterval = 0
    private var fallSpeed: CGFloat = 0
    private var busy = false                              // an answer is streaming in
    private var timer: Timer?
    private var stageWidth: CGFloat = 640

    private let runSpeed: CGFloat = 130                   // points per second
    private let tick: TimeInterval = 1.0 / 30

    private var cell: CGSize { DuckSprites.cellSize }
    private var minX: CGFloat { 10 }
    private var maxX: CGFloat { stageWidth - cell.width - 10 }

    // MARK: - Lifecycle

    /// Called when the popup opens: pick a random entrance and start animating.
    func start(stageWidth: CGFloat, dropHeight: CGFloat) {
        stop()
        self.stageWidth = stageWidth
        busy = false
        queue = []
        clock = 0

        // With "Reduce motion" turned on in macOS, the duck just sits there.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            x = minX + 20; y = 0; facingLeft = false
            frame = DuckSprites.frames[.idle]?.first
            return
        }

        let target = CGFloat.random(in: minX + 40 ... max(minX + 41, maxX * 0.6))
        switch Int.random(in: 0..<3) {
        case 0:   // runs in from the left edge
            x = -cell.width; y = 0; facingLeft = false
            set(.run(to: target))
        case 1:   // hops in from the left edge, three hops
            x = -cell.width * 0.7; y = 0; facingLeft = false
            let hop = (target - x) / 3
            set(.jump(dx: hop)); queue = [.jump(dx: hop), .jump(dx: hop)]
        default:  // drops in from above, tumbling, then lands
            x = target; y = -dropHeight; facingLeft = Bool.random()
            fallSpeed = 0
            set(.fall)
        }
        step(0)
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(self?.tick ?? 0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called when the popup closes: no timer runs while it's hidden.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// While an answer streams in, the duck runs back and forth; when it's done, a happy hop.
    func setBusy(_ isBusy: Bool) {
        guard isBusy != busy, timer != nil else { return }
        busy = isBusy
        if isBusy {
            if case .fall = action { return }             // let it land first
            if case .land = action { return }
            queue = []
            set(.run(to: x < (minX + maxX) / 2 ? maxX : minX))
        } else {
            queue = []
            set(.jump(dx: 0))
        }
    }

    // MARK: - Animation

    private func set(_ new: Action) {
        action = new
        actionTime = 0
        if case .run(let to) = new { facingLeft = to < x }
        if case .jump(let dx) = new, dx != 0 { facingLeft = dx < 0 }
    }

    private func next() {
        if !queue.isEmpty { set(queue.removeFirst()); return }
        if busy { set(.run(to: x < (minX + maxX) / 2 ? maxX : minX)); return }
        set(.idle(until: clock + .random(in: 2.5...6)))
    }

    /// Something to do every few seconds, so it never looks frozen.
    private func pickIdleBehaviour() {
        switch Int.random(in: 0..<10) {
        case 0..<4: set(.run(to: .random(in: minX...maxX)))           // wander somewhere
        case 4..<7: set(.jump(dx: 0))                                  // hop in place
        case 7:     set(.jump(dx: facingLeft ? -40 : 40))              // hop forward
        case 8:     facingLeft.toggle(); set(.idle(until: clock + .random(in: 2...4)))   // look the other way
        default:    set(.idle(until: clock + .random(in: 2...5)))      // just chill
        }
        // Keep hops on the bar.
        if case .jump(let dx) = action, x + dx < minX || x + dx > maxX { set(.jump(dx: -dx)) }
    }

    private func step(_ dt: TimeInterval) {
        clock += dt
        actionTime += dt
        let f = DuckSprites.frames

        switch action {
        case .idle(let until):
            frame = f[.idle]?[Int(actionTime / 0.2) % 4]
            if busy { next() } else if clock >= until { pickIdleBehaviour() }

        case .run(let to):
            frame = f[.run]?[Int(actionTime / 0.07) % 6]
            let distance = to - x
            let move = runSpeed * CGFloat(dt)
            if abs(distance) <= move { x = to; next() } else { x += distance > 0 ? move : -move }

        case .jump(let dx):
            let duration = 0.08 * 6
            let index = Int(actionTime / 0.08)
            if index >= 6 { next(); break }
            frame = f[.jump]?[index]
            x += dx * CGFloat(dt / duration)

        case .fall:
            fallSpeed += 1100 * CGFloat(dt)                 // gravity
            y = min(0, y + fallSpeed * CGFloat(dt))
            frame = f[.fall]?[Int(actionTime / 0.1) % 2]    // tumbling frames
            if y >= 0 { set(.land) }

        case .land:
            let index = Int(actionTime / 0.12)
            if index >= 2 { next(); break }
            frame = f[.fall]?[2 + index]                    // landing frames
        }
    }
}

/// Draws the current frame at the controller's position.
struct DuckView: View {
    @ObservedObject var duck: DuckController

    var body: some View {
        let cell = DuckSprites.cellSize
        ZStack(alignment: .bottomLeading) {
            Color.clear
            if let frame = duck.frame {
                Image(nsImage: frame)
                    .interpolation(.none)                    // keep the pixels sharp
                    .resizable()
                    .frame(width: cell.width, height: cell.height)
                    .scaleEffect(x: duck.facingLeft ? -1 : 1, y: 1)   // the art faces right
                    // Snap to whole screen pixels so the pixel art doesn't shimmer.
                    .offset(x: (duck.x * 2).rounded() / 2,
                            y: (duck.y * 2).rounded() / 2 + DuckSprites.footPadding)
            }
        }
    }
}

/// The transparent, click-through window the duck lives in.
@MainActor
final class DuckWindow {
    let controller = DuckController()
    private let window: NSPanel
    private var busySubscription: AnyCancellable?
    private weak var model: ChatModel?

    /// How much room above the bar the duck has (for jumps and dropping in).
    static let stageHeight: CGFloat = DuckSprites.cellSize.height + 110

    init(width: CGFloat, observing model: ChatModel) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.stageHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false                       // a moving shape + window shadow = ghost trails
        window.ignoresMouseEvents = true               // clicks go straight through
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DuckView(duck: controller))
        hosting.sizingOptions = []
        window.contentView = hosting

        self.model = model
        busySubscription = model.$isStreaming
            .removeDuplicates()
            .sink { [weak self] streaming in self?.controller.setBusy(streaming) }
    }

    /// Shows the duck standing on the top edge of the popup (`barFrame`).
    func show(above barFrame: NSRect) {
        place(above: barFrame)
        window.orderFront(nil)
        controller.start(stageWidth: barFrame.width, dropHeight: Self.stageHeight)
        // Reopened while an answer is still arriving in the background: keep running.
        if model?.isStreaming == true { controller.setBusy(true) }
    }

    func place(above barFrame: NSRect) {
        // 2 pt lower than the bar's top edge, so the feet stand *on* the edge.
        window.setFrame(NSRect(x: barFrame.minX, y: barFrame.maxY - 2,
                               width: barFrame.width, height: Self.stageHeight), display: false)
    }

    func hide() {
        controller.stop()
        window.orderOut(nil)
    }
}

/// The duck's quack (Resources/quack.wav), played when an answer is ready.
@MainActor
enum DuckSound {
    private static let sound: NSSound? = Bundle.main.url(forResource: "quack", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    static func quack() {
        guard let sound else { return }
        sound.stop()                                   // restart if it's somehow still playing
        sound.play()
    }
}
