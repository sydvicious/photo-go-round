// What `WallpaperAgent` calls, and what this extension answers. `Wallpaper
// Plan.md`, *The second probe*, *What the third probe found* and *What the fourth
// probe found* hold the measurements; this is the same code, grown up.
//
// The selectors are the ones Phosphene declares for the same protocol. The
// arguments are private classes from `WallpaperExtensionKit`, so they are `Any`
// here: logged, and read only where `Mirror` can reach a field this needs.

import AVFoundation
import CoreGraphics
import Foundation
import PhotosGoRoundAgentAPI
import IOSurface
import ObjectiveC
import QuartzCore

@objc(WallpaperExtensionXPCProtocol)
protocol WallpaperExtensionXPC: NSObjectProtocol {
    @objc(acquireWithId:request:reply:)
    func acquire(id: Any?, request: Any?, reply: @escaping (Any?, (any Error)?) -> Void)
    @objc(updateWithId:request:reply:)
    func update(id: Any?, request: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(invalidateWithId:reply:)
    func invalidate(id: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(snapshotWithId:reply:)
    func snapshot(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void)

    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettingsViewModels(contentTypes: Any?, reply: @escaping (Any?, (any Error)?) -> Void)

    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:)
    func addChoiceRequest(_ request: Any?, onBehalfOf process: Any?, reply: @escaping (Any?, (any Error)?) -> Void)
    @objc(removeChoiceRequestWithChoiceRequest:reply:)
    func removeChoiceRequest(_ request: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(selectedChoicesDidChangeFor:reply:)
    func selectedChoicesDidChange(id: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:)
    func invokeContextMenuAction(menuItemID: Any?, groupItemID: Any?, reply: @escaping ((any Error)?) -> Void)

    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(_ choice: Any?, reply: @escaping (Bool, (any Error)?) -> Void)
    @objc(downloadWithChoiceID:reply:)
    func download(choiceID: Any?, reply: @escaping ((any Error)?) -> Void) -> Progress?
    @objc(pauseDownloadFor:reply:)
    func pauseDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(cancelDownloadFor:reply:)
    func cancelDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(resumeDownloadFor:reply:)
    func resumeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(removeDownloadFor:reply:)
    func removeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void)

    @objc(migrateSelectedChoiceFor:reply:)
    func migrateSelectedChoice(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void)
    @objc(migrateFrom:to:reply:)
    func migrate(from: Any?, to: Any?, reply: @escaping ((any Error)?) -> Void)

    @objc(skipShuffledContentWithId:reply:)
    func skipShuffledContent(id: Any?, reply: @escaping ((any Error)?) -> Void)
    @objc(canSkipShuffledContentWithId:reply:)
    func canSkipShuffledContent(id: Any?, reply: @escaping (Bool, (any Error)?) -> Void)

    @objc(handleDebugRequestFor:reply:)
    func handleDebugRequest(_ request: Any?, reply: @escaping (Any?, (any Error)?) -> Void)
    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(name: Any?, reply: @escaping ((any Error)?) -> Void)
}

/// Which of the two things a surface is: the desktop, or the screen saver.
///
/// `WallpaperAgent` says so in the `acquire` request's `presentationMode` —
/// `default` for the desktop and every preview of it, `idle` for the screen
/// saver. Measured 2026-09-15. They keep their own photographs, so choosing
/// Photos-Go-Round for both does not show the same picture twice.
enum Slot: String, Sendable {
    case desktop
    case idle

    var name: String { self == .desktop ? "desktop" : "screen saver" }
}

/// The private classes that cross the connection. XPC refuses to decode an
/// argument of a class it was not told about, so each one is named here and
/// allowed on every object-typed argument.
enum PrivateTypes {
    static let names = [
        "WallpaperIDXPC",
        "WallpaperCreationRequestXPC",
        "WallpaperUpdateRequestXPC",
        "WallpaperRemoteContextXPC",
        "WallpaperSnapshotXPC",
        "WallpaperContentTypeSetXPC",
        "WallpaperChoiceIDXPC",
        "WallpaperChoiceIDsXPC",
        "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC",
        "WallpaperDebugRequestXPC",
        "WallpaperDebugResponseXPC",
        "WallpaperMigrationVersionXPC",
        "WallpaperSettingsViewModelsXPC",
        "AuditTokenXPC",
    ]

    /// Every object-typed argument, as selector, argument index, and whether it
    /// belongs to the reply block.
    static let objectArguments: [(selector: String, index: Int, ofReply: Bool)] = [
        ("acquireWithId:request:reply:", 0, false),
        ("acquireWithId:request:reply:", 1, false),
        ("acquireWithId:request:reply:", 0, true),
        ("updateWithId:request:reply:", 0, false),
        ("updateWithId:request:reply:", 1, false),
        ("invalidateWithId:reply:", 0, false),
        ("snapshotWithId:reply:", 0, false),
        ("snapshotWithId:reply:", 0, true),
        ("provideSettingsViewModelsWithContentTypes:reply:", 0, false),
        ("provideSettingsViewModelsWithContentTypes:reply:", 0, true),
        ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 0, false),
        ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 1, false),
        ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 0, true),
        ("removeChoiceRequestWithChoiceRequest:reply:", 0, false),
        ("selectedChoicesDidChangeFor:reply:", 0, false),
        ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", 0, false),
        ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", 1, false),
        ("isChoiceDownloadedWith:reply:", 0, false),
        ("downloadWithChoiceID:reply:", 0, false),
        ("pauseDownloadFor:reply:", 0, false),
        ("cancelDownloadFor:reply:", 0, false),
        ("resumeDownloadFor:reply:", 0, false),
        ("removeDownloadFor:reply:", 0, false),
        ("migrateSelectedChoiceFor:reply:", 0, false),
        ("migrateSelectedChoiceFor:reply:", 0, true),
        ("migrateFrom:to:reply:", 0, false),
        ("migrateFrom:to:reply:", 1, false),
        ("skipShuffledContentWithId:reply:", 0, false),
        ("canSkipShuffledContentWithId:reply:", 0, false),
        ("handleDebugRequestFor:reply:", 0, false),
        ("handleDebugRequestFor:reply:", 0, true),
        ("handleNotificationWithNamed:reply:", 0, false),
    ]

    static func exportedInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: (any WallpaperExtensionXPC).self)
        let classes = NSMutableSet()
        for name in names {
            if let found = NSClassFromString(name) { classes.add(found) }
        }
        for plain: AnyClass in [
            NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self,
        ] {
            classes.add(plain)
        }
        let allowed = classes as! Set<AnyHashable>
        for argument in objectArguments {
            let selector = NSSelectorFromString(argument.selector)
            // `setClasses` raises for a selector the protocol does not declare,
            // and a raised exception ends the process. Check first.
            guard protocol_getMethodDescription(interface.protocol, selector, true, true).name != nil else {
                wallpaperLog("interface: \(argument.selector) is not in the protocol; skipped")
                continue
            }
            interface.setClasses(allowed, for: selector, argumentIndex: argument.index, ofReply: argument.ofReply)
        }
        return interface
    }
}

final class PaneHandler: NSObject, WallpaperExtensionXPC {
    private let caller: Int32

    init(caller: Int32) {
        self.caller = caller
        super.init()
        // Once per process, however many panes ask; see `Footprint`.
        Footprint.startLogging { wallpaperLog($0) }
    }

    private func heard(_ call: String, _ arguments: Any?...) {
        wallpaperLog("\(call) from pid \(caller): \(arguments.map(described).joined(separator: " | "))")
    }

    // MARK: - The pane

    func provideSettingsViewModels(contentTypes: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("provideSettingsViewModels", contentTypes)
        // **Which picker is asking.** `screenSaver: nil` in the view models did
        // not keep the section out of the Screen Saver picker, so the argument
        // is read rather than assumed: it is the pane saying what it wants, and
        // nothing in the plan records its shape. Logged before it is used.
        wallpaperLog("provideSettingsViewModels: content types \(Reflected(contentTypes).valuesSummary)")
        guard let thumbnail = PaneThumbnail.url else {
            reply(nil, wallpaperError(1, "no thumbnail"))
            return
        }
        guard let answer = PaneModels.archived(thumbnail: thumbnail) else {
            reply(nil, wallpaperError(2, "view models could not be built"))
            return
        }
        reply(answer, nil)
    }

    // MARK: - A surface per display

    /// The desktop, and the pane's preview. The generated mark goes up at once so
    /// the desktop is never blank, and the photograph replaces it when the agent
    /// answers — measured in the fourth probe, where a second `enqueueImmediately`
    /// on the same receiver swapped the picture.
    func acquire(id: Any?, request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("acquire", id)
        let fields = Reflected(request)
        // **Which slot this surface is for.** Only size, scale, display and
        // `isPreview` have ever been read; refusing the screen saver needs to
        // know whether the request says so. Logged whole, once, rather than
        // guessed at — `screenSaver: nil` in the view models stopped the item
        // being offered and did nothing about a selection already made.
        // **Which slot this surface fills.** `presentationMode` is `default` for
        // the desktop and every preview, and `idle` for the screen saver —
        // measured twice on 2026-09-15, both with `isPreview` false.
        //
        // The two slots keep their own photographs. Syd, having tried refusing
        // the screen saver first: "so the refuse option sucks" — it left an entry
        // in the Screen Saver list that silently produced Apple's screen saver,
        // and did nothing about the previews. Serving both, independently, is
        // what makes each choice mean something.
        let mode = described(fields.rawValue(named: "presentationMode"))
        let slot: Slot = mode == "idle" ? .idle : .desktop
        wallpaperLog("acquire: presentationMode \(mode), serving the \(slot.name)")
        let size = fields.value(named: "size", as: CGSize.self) ?? CGSize(width: 1920, height: 1080)
        let scale =
            fields.value(named: "scaleFactor", as: CGFloat.self)
            ?? fields.value(named: "scaleFactor", as: Double.self).map { CGFloat($0) } ?? 2
        let display = fields.value(named: "directDisplayID", as: UInt32.self)
        let preview = fields.value(named: "isPreview", as: Bool.self)
        wallpaperLog(
            "acquire: \(Int(size.width))x\(Int(size.height)) at \(scale)x, display \(display.map { String($0) } ?? "unknown"), preview \(preview.map { String($0) } ?? "unknown")"
        )

        // **Keyed by the wallpaper's own UUID.** Every `acquire` carries one in
        // its `WallpaperIDXPC`, and it is the only identity that is unique and
        // stable: the id object's address is neither — keying by it left the
        // desktop grey in the third probe — and the role, "display 1, preview",
        // is not unique over time. `WallpaperAgent` acquires the preview more
        // than once, and keying by role meant the second acquire replaced the
        // first, freeing a context the pane was still showing. Measured
        // 2026-09-15: the preview went blank and stopped following the desktop.
        let key = Reflected(id).value(named: "id", as: UUID.self).map(\.uuidString) ?? described(id)
        nonisolated(unsafe) let send = reply

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // The preview shows what the desktop shows. Syd, 2026-09-15:
                // "the preview should update with the current picture." It uses
                // the photograph already in hand rather than asking for one of
                // its own, so opening System Settings still spends no card.
                // **Every surface starts from a photograph of its own slot.** The
                // slot's current picture, or the last one it kept on disk, which
                // outlives both the surfaces and this process. The mark is the
                // last resort, for a slot that has never been served.
                //
                // Per slot, so the screen saver does not mirror the desktop: one
                // provider, two pictures.
                let remembered = Surfaces.shown(on: slot) ?? LastPicture.image(for: slot)
                let first = remembered ?? PaneThumbnail.image
                guard let first, let still = Still.sample(of: first) else {
                    send(nil, wallpaperError(3, "no picture to show"))
                    return
                }
                guard let surface = RemoteSurface.make(size: size, scale: scale, display: display, still: still),
                    let answer = RemoteSurface.reply(for: surface.contextID)
                else {
                    send(nil, wallpaperError(4, "no remote context"))
                    return
                }
                Surfaces.keep(surface, for: key, display: display, isPreview: preview == true, slot: slot)
                send(answer, nil)

                // **A preview asks only when it has nothing to copy.**
                //
                // Browsing the pane while the desktop is ours costs no card: the
                // preview starts from the picture on the desktop and follows it
                let pixels = CGSize(width: size.width * scale, height: size.height * scale)
                // **One rotation per display, whatever acquires it.**
                //
                // A preview with a photograph in hand — the desktop's, or the
                // last one kept on disk — needs nothing. A preview with neither,
                // on a Mac where nothing has been served yet, asks **once**: it
                // must not start a timer, because the desktop's rotation is the
                // display's rotation. Measured 2026-09-15, when it did start one:
                // two rotations for one display, two cards an hour, and a second
                // photograph arriving seconds after the first.
                if preview == true {
                    guard remembered == nil else { return }
                    Surfaces.askOnce(display: display, pixels: pixels, slot: slot)
                    return
                }
                Surfaces.rotate(key: key, display: display, pixels: pixels, slot: slot)
            }
        }
    }

    func update(id: Any?, request: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("update", id)
        reply(nil)
    }

    /// The one surface `WallpaperAgent` is finished with, by the same UUID it was
    /// acquired under.
    ///
    /// **Only that one.** Phosphene found that tearing everything down on an
    /// invalidate blanked the desktop, because the agent drops and re-acquires
    /// around every change; dropping exactly what it named does not.
    func invalidate(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("invalidate", id)
        if let key = Reflected(id).value(named: "id", as: UUID.self).map(\.uuidString) {
            Surfaces.forget(key)
        }
        reply(nil)
    }

    /// The export `WallpaperAgent` makes, which is also what the lock screen
    /// shows. Whatever the desktop is showing now, so it follows the rotation.
    func snapshot(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("snapshot", id)
        let pixels = Surfaces.desktopPixels ?? CGSize(width: 1920, height: 1080)
        // The export is the desktop's; the screen saver has no snapshot of its own.
        guard let picture = Surfaces.shown(on: .desktop) ?? LastPicture.image(for: .desktop) ?? PaneThumbnail.image,
            let surface = Still.surface(of: picture, pixels: pixels),
            let answer = SnapshotReply.make(surface: surface)
        else {
            reply(nil, wallpaperError(5, "no snapshot"))
            return
        }
        reply(answer, nil)
    }

    // MARK: - Everything else, answered empty

    func addChoiceRequest(_ request: Any?, onBehalfOf process: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("addChoiceRequest")
        reply(nil, nil)
    }

    func removeChoiceRequest(_ request: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("removeChoiceRequest")
        reply(nil)
    }

    func selectedChoicesDidChange(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("selectedChoicesDidChange")
        reply(nil)
    }

    func invokeContextMenuAction(menuItemID: Any?, groupItemID: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("invokeContextMenuAction")
        reply(nil)
    }

    func isChoiceDownloaded(_ choice: Any?, reply: @escaping (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    func download(choiceID: Any?, reply: @escaping ((any Error)?) -> Void) -> Progress? {
        reply(nil)
        return nil
    }

    func pauseDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }

    func migrateSelectedChoice(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func migrate(from: Any?, to: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }

    func skipShuffledContent(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("skipShuffledContent", id)
        reply(nil)
    }

    func canSkipShuffledContent(id: Any?, reply: @escaping (Bool, (any Error)?) -> Void) { reply(false, nil) }

    func handleDebugRequest(_ request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func handleNotification(name: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }

}

/// A free function rather than a method: the reply is built inside a `@Sendable`
/// closure on the main thread, and a method would capture the handler with it.
func wallpaperError(_ code: Int, _ text: String) -> NSError {
    wallpaperLog("answering with an error: \(text)")
    // **This build's own identifier, not a literal.** It was
    // `com.sydpolk.photosgoround.wallpaper-extension` until 2026-09-19 — the
    // spelling the bundle carried before the 2026-09-15 rename, so an error
    // named a bundle that no longer existed, in a log somebody would be
    // grepping by identifier. Each configuration now answers under its own:
    // `…wallpaper.extension`, `…wallpaper.debug.extension`,
    // `…wallpaper.claude.extension`.
    return NSError(
        domain: Bundle.main.bundleIdentifier ?? "com.sydpolk.photosgoround.wallpaper.extension",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: text])
}

/// A remote Core Animation context holding one still. `CAContext` is private
/// QuartzCore API, reached by name so nothing links against it.
///
/// **The still is an `AVSampleBufferDisplayLayer`, not a layer's `contents`.**
/// Phosphene's author recorded that plain `contents` composites black in
/// `WallpaperAgent`, and that only IOSurface-backed sample buffers show.
final class RemoteSurface {
    let context: NSObject
    let root: CALayer
    let still: AVSampleBufferDisplayLayer
    /// Held for as long as the surface: the receiver is how the layer was handed
    /// its frame, and belongs to this synchronizer.
    let synchronizer: AVSampleBufferRenderSynchronizer
    let receiver: AVSampleBufferVideoRenderer.Receiver
    let contextID: UInt32
    /// The rotation for this surface, cancelled when the surface is replaced.
    var rotation: Task<Void, Never>?

    private init(
        context: NSObject, root: CALayer, still: AVSampleBufferDisplayLayer,
        synchronizer: AVSampleBufferRenderSynchronizer, receiver: AVSampleBufferVideoRenderer.Receiver,
        contextID: UInt32
    ) {
        self.context = context
        self.root = root
        self.still = still
        self.synchronizer = synchronizer
        self.receiver = receiver
        self.contextID = contextID
    }

    @MainActor
    static func make(size: CGSize, scale: CGFloat, display: UInt32?, still sample: sending CMSampleBuffer)
        -> RemoteSurface?
    {
        guard let contextClass = NSClassFromString("CAContext") else {
            wallpaperLog("remote context: no CAContext class")
            return nil
        }
        let factory: AnyObject = contextClass
        let made: Unmanaged<AnyObject>?
        if let display {
            made = factory.perform(NSSelectorFromString("remoteContextWithOptions:"), with: ["displayId": display])
        } else {
            made = factory.perform(NSSelectorFromString("remoteContext"))
        }
        guard let context = made?.takeUnretainedValue() as? NSObject,
            let contextID = (context.value(forKey: "contextId") as? NSNumber)?.uint32Value, contextID != 0
        else {
            wallpaperLog("remote context: none created")
            return nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        let still = AVSampleBufferDisplayLayer()
        still.frame = root.bounds
        still.contentsScale = scale
        still.videoGravity = .resizeAspect
        root.addSublayer(still)
        context.setValue(root, forKey: "layer")
        CATransaction.commit()

        let synchronizer = AVSampleBufferRenderSynchronizer()
        let receiver = synchronizer.sampleBufferReceiver(adding: still.sampleBufferRenderer)
        _ = receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample))
        CATransaction.flush()

        wallpaperLog("remote context \(contextID) at \(Int(size.width))x\(Int(size.height))")
        return RemoteSurface(
            context: context, root: root, still: still, synchronizer: synchronizer, receiver: receiver,
            contextID: contextID)
    }

    /// A new still on the same layer, through the same receiver.
    @MainActor
    func show(_ image: CGImage) -> Bool {
        guard let sample = Still.sample(of: image) else { return false }
        _ = receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample))
        CATransaction.flush()
        wallpaperLog("remote context \(contextID) now shows a \(image.width)x\(image.height) picture")
        return true
    }

    /// `WallpaperRemoteContextXPC` carrying the context id in its `box` ivar,
    /// which is how Phosphene answers. Fails closed if the class's layout is not
    /// the one expected, rather than writing past the instance.
    static func reply(for contextID: UInt32) -> AnyObject? {
        guard let replyClass = NSClassFromString("WallpaperRemoteContextXPC"),
            let created = class_createInstance(replyClass, 0)
        else {
            wallpaperLog("reply: WallpaperRemoteContextXPC could not be created")
            return nil
        }
        guard let box = class_getInstanceVariable(replyClass, "box") else {
            wallpaperLog("reply: WallpaperRemoteContextXPC has no box ivar")
            return nil
        }
        let offset = ivar_getOffset(box)
        guard offset >= 0, offset + MemoryLayout<UInt32>.size <= class_getInstanceSize(replyClass) else {
            wallpaperLog("reply: box at offset \(offset) does not fit")
            return nil
        }
        let instance = created as AnyObject
        Unmanaged.passUnretained(instance).toOpaque().advanced(by: offset).storeBytes(of: contextID, as: UInt32.self)
        return instance
    }
}

/// The surfaces this extension is holding, and what each is showing.
///
/// Surfaces outlive the connection that asked for them: a context nobody holds is
/// freed, and the desktop goes blank.
enum Surfaces {
    /// A surface and what it is for. The display says which screen's photograph
    /// belongs on it; `isPreview` says whether it asks for one of its own.
    struct Held {
        let surface: RemoteSurface
        let display: UInt32?
        let isPreview: Bool
        /// Which slot this surface fills. A photograph goes only to the surfaces
        /// of its own slot, so the screen saver and the desktop differ.
        let slot: Slot
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [String: Held] = [:]
    nonisolated(unsafe) private static var shown: [Slot: CGImage] = [:]
    nonisolated(unsafe) private static var desktopSize: CGSize?

    /// What a slot is showing now, for a new surface of the same slot and for
    /// `snapshot`.
    static func shown(on slot: Slot) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return shown[slot]
    }

    static var desktopPixels: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return desktopSize
    }

    @MainActor
    static func keep(_ surface: RemoteSurface, for key: String, display: UInt32?, isPreview: Bool, slot: Slot) {
        lock.lock()
        let previous = held[key]
        held[key] = Held(surface: surface, display: display, isPreview: isPreview, slot: slot)
        let count = held.count
        lock.unlock()
        // Only a surface acquired under the same UUID is replaced, and that one
        // really is finished with.
        previous?.surface.rotation?.cancel()
        wallpaperLog(
            "holding \(count) surface\(count == 1 ? "" : "s"); \(slot.name)\(isPreview ? " preview" : "") for display \(display.map { String($0) } ?? "unknown"), \(key)"
        )
    }

    /// Drop the surface `WallpaperAgent` says it is finished with.
    static func forget(_ key: String) {
        lock.lock()
        let going = held.removeValue(forKey: key)
        let count = held.count
        lock.unlock()
        guard let going else { return }
        going.surface.rotation?.cancel()
        wallpaperLog(
            "released the \(going.slot.name)\(going.isPreview ? " preview" : "") surface \(key); holding \(count)")
    }

    /// Ask the agent now, and again on every interval, for as long as this
    /// surface is the one being shown on that display.
    /// One picture, now, with no timer behind it.
    ///
    /// For a preview that has nothing to show on a Mac where the desktop has
    /// never been ours. The desktop's own rotation, when there is one, is what
    /// keeps the display moving.
    @MainActor
    static func askOnce(display: UInt32?, pixels: CGSize, slot: Slot) {
        wallpaperLog("\(slot.name) preview has nothing to show; asking once, with no rotation")
        AgentPicture.fetch(display: display, pixels: pixels, slot: slot) { answer in
            guard let answer else { return }
            if answer.isMessage {
                LastPicture.forget(for: slot)
            } else {
                LastPicture.remember(answer.image, card: answer.card, for: slot)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { show(answer.image, on: display, slot: slot) }
            }
        }
    }

    /// The display's rotation: one, held by its desktop surface.
    ///
    /// **Replacing a desktop surface replaces its rotation.** `keep` cancels the
    /// one the previous surface held, so re-acquiring a display does not leave a
    /// timer behind asking for pictures nobody draws.
    @MainActor
    static func rotate(key: String, display: UInt32?, pixels: CGSize, slot: Slot) {
        lock.lock()
        let entry = held[key]
        if slot == .desktop { desktopSize = pixels }
        lock.unlock()
        guard let entry else { return }

        // **Answers what arrived**, because `Rotation` decides when to ask again
        // from that: a refusal is worth ten seconds, not a whole rotation, and
        // so is the empty state's message. The first ask is the loop's too — it used to be made here,
        // where nothing could see whether it worked, and it is the ask that
        // fails most often because the agent is not listening yet after a boot.
        let ask: @Sendable () async -> Rotation.Asked = {
            await withCheckedContinuation { continuation in
                AgentPicture.fetch(display: display, pixels: pixels, slot: slot) { answer in
                    guard let answer else {
                        continuation.resume(returning: .nothing)
                        return
                    }
                    // Kept before it is drawn, so a surface acquired after this
                    // process dies still has a photograph to show. **Not the
                    // message**: a relaunch would open on words that may no
                    // longer be true, where a photograph is only old — and the
                    // photograph kept before it goes, since it can no longer be
                    // served either.
                    if answer.isMessage {
                        LastPicture.forget(for: slot)
                    } else {
                        LastPicture.remember(answer.image, card: answer.card, for: slot)
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { show(answer.image, on: display, slot: slot) }
                    }
                    continuation.resume(returning: answer.isMessage ? .message : .picture)
                }
            }
        }
        entry.surface.rotation = Rotation.run(ask)
        wallpaperLog(
            "the \(slot.name) on display \(display.map { String($0) } ?? "unknown") will ask again every \(Rotation.interval.rawValue)"
        )
    }

    /// The new photograph, on every live surface for that display.
    ///
    /// **Every one, not the one that asked.** A display has a desktop surface and,
    /// while System Settings is open, one or more previews; they are all showing
    /// the same wallpaper and should all change together. Surfaces the agent has
    /// invalidated are gone from the table, so nothing draws into a context
    /// nobody is watching.
    @MainActor
    static func show(_ image: CGImage, on display: UInt32?, slot: Slot) {
        lock.lock()
        shown[slot] = image
        let matching = held.filter { $0.value.display == display && $0.value.slot == slot }
        lock.unlock()
        guard !matching.isEmpty else {
            wallpaperLog(
                "no \(slot.name) surface left for display \(display.map { String($0) } ?? "unknown"); picture dropped")
            return
        }
        var drawn = 0
        for (_, entry) in matching where entry.surface.show(image) { drawn += 1 }
        wallpaperLog(
            "showed a \(image.width)x\(image.height) picture on \(drawn) of \(matching.count) \(slot.name) surfaces")
    }
}

/// A still, as an IOSurface-backed sample buffer for the layer and as a plain
/// IOSurface for the snapshot.
enum Still {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// One frame, marked to display at once.
    static func sample(of image: CGImage) -> CMSampleBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &created) == kCVReturnSuccess,
            let buffer = created
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let drew: Bool = {
            guard
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drew else { return nil }

        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
            let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// The picture in a BGRA `IOSurface` of `pixels`, aspect fit on black — the
    /// form `snapshot` is answered with.
    static func surface(of image: CGImage, pixels: CGSize) -> IOSurface? {
        let width = max(Int(pixels.width), 1)
        let height = max(Int(pixels.height), 1)
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard
            let context = CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fit = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                width: drawn.width, height: drawn.height))
        return surface
    }
}

/// `WallpaperSnapshotXPC` carrying an IOSurface in its `rawValue` ivar, which
/// `encodeWithCoder:` turns into an XPC object with `IOSurfaceCreateXPCObject` —
/// disassembled 2026-09-15. Fails closed if the layout is not the one expected.
enum SnapshotReply {
    static func make(surface: IOSurface) -> AnyObject? {
        guard let snapshotClass = NSClassFromString("WallpaperSnapshotXPC") else {
            wallpaperLog("snapshot: WallpaperSnapshotXPC is not loaded")
            return nil
        }
        guard let rawValue = class_getInstanceVariable(snapshotClass, "rawValue") else {
            wallpaperLog("snapshot: WallpaperSnapshotXPC has no rawValue ivar")
            return nil
        }
        let offset = ivar_getOffset(rawValue)
        guard offset >= 0,
            offset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(snapshotClass),
            let created = class_createInstance(snapshotClass, 0)
        else {
            wallpaperLog("snapshot: rawValue at offset \(offset) does not fit")
            return nil
        }
        let instance = created as AnyObject
        let retained = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(instance).toOpaque().advanced(by: offset)
            .storeBytes(of: retained, as: UnsafeMutableRawPointer.self)
        return instance
    }
}

/// Apple's request objects, read by reflection: no SDK header declares them.
struct Reflected {
    private(set) var fields: [(path: String, value: Any)] = []

    init(_ root: Any?) {
        guard let root else { return }
        walk(root, path: "", depth: 6)
    }

    private mutating func walk(_ value: Any, path: String, depth: Int) {
        guard depth > 0, fields.count < 300 else { return }
        for child in Mirror(reflecting: value).children {
            let label = child.label ?? "_"
            let childPath = path.isEmpty ? label : "\(path).\(label)"
            fields.append((childPath, child.value))
            // A `Data`'s bytes swamp the log line and hold nothing worth reading.
            if child.value is Data { continue }
            walk(child.value, path: childPath, depth: depth - 1)
        }
    }

    func value<T>(named name: String, as _: T.Type) -> T? {
        fields.first { ($0.path == name || $0.path.hasSuffix(".\(name)")) && $0.value is T }?.value as? T
    }

    /// Every field with its value, for a small object worth reading whole — the
    /// pane's content types, say, where the shape is not yet known.
    var valuesSummary: String {
        fields.isEmpty
            ? "none visible"
            : fields.prefix(20).map { "\($0.path) = \(described($0.value))" }.joined(separator: ", ")
    }

    /// One field's value, whatever its type, by the last component of its path.
    func rawValue(named name: String) -> Any? {
        fields.first { $0.path == name || $0.path.hasSuffix(".\(name)") }?.value
    }

    /// Just the field names, whole. `valuesSummary` truncates every value and
    /// stops at twenty fields, which hid the ones that mattered when the question
    /// was "does this request name the slot it is for" — the answer was buried
    /// past the cap. Names alone are short enough to print in full.
    var pathsSummary: String {
        fields.isEmpty ? "none visible" : fields.map(\.path).joined(separator: ", ")
    }
}

func described(_ value: Any?) -> String {
    guard let value else { return "nil" }
    let text = String(describing: value)
    return text.count > 300 ? String(text.prefix(300)) + "…" : text
}
