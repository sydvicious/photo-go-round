// What `WallpaperAgent` calls, and the probe's answers. `Wallpaper Plan.md`,
// *The second probe*, *The third probe: snapshots and the lock screen* and *The
// fourth probe: pictures from the agent*.
//
// The selectors are the ones Phosphene declares for the same protocol. The
// arguments are private classes from `WallpaperExtensionKit`, so they are `Any`
// here: described in the log, and read only where `Mirror` can reach a field the
// probe needs.

import AVFoundation
import Foundation
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
                probe("interface: \(argument.selector) is not in the protocol; skipped")
                continue
            }
            interface.setClasses(allowed, for: selector, argumentIndex: argument.index, ofReply: argument.ofReply)
        }
        return interface
    }
}

final class PaneHandler: NSObject, WallpaperExtensionXPC {
    /// False in the 0.3.1 bisect build, true again in 0.3.2; see `snapshot`.
    static let answersSnapshots = true

    private let caller: Int32

    init(caller: Int32) {
        self.caller = caller
        super.init()
    }

    private func heard(_ call: String, _ arguments: Any?...) {
        probe("\(call) from pid \(caller): \(arguments.map(described).joined(separator: " | "))")
    }

    // MARK: - The pane

    /// Gate 1. One Photo-Go-Round section holding one item.
    func provideSettingsViewModels(contentTypes: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("provideSettingsViewModels", contentTypes)
        guard let thumbnail = ProbePicture.thumbnailURL else {
            probe("provideSettingsViewModels: no thumbnail, so nothing to answer with")
            reply(nil, probeError(1, "no thumbnail"))
            return
        }
        guard let answer = PaneModels.archived(thumbnail: thumbnail) else {
            reply(nil, probeError(2, "view models could not be built"))
            return
        }
        probe("provideSettingsViewModels: answered with a \(NSStringFromClass(type(of: answer)))")
        reply(answer, nil)
    }

    // MARK: - A surface

    /// Gates 2 and 3. A remote context showing the picture, and its id in
    /// `WallpaperAgent`'s reply class.
    func acquire(id: Any?, request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("acquire", id, request)
        probe("acquire: id fields \(Reflected(id).valuesSummary)")
        let fields = Reflected(request)
        probe("acquire: request fields \(fields.summary)")

        let size = fields.value(named: "size", as: CGSize.self) ?? CGSize(width: 1920, height: 1080)
        let scale = fields.value(named: "scaleFactor", as: CGFloat.self)
            ?? fields.value(named: "scaleFactor", as: Double.self).map { CGFloat($0) } ?? 2
        let display = fields.value(named: "directDisplayID", as: UInt32.self)
        let preview = fields.value(named: "isPreview", as: Bool.self)
        probe(
            "acquire: \(Int(size.width))x\(Int(size.height)) at \(scale)x, display \(display.map { String($0) } ?? "not found"), preview \(preview.map { String($0) } ?? "not found")")
        if preview == false {
            DesktopSize.remember(CGSize(width: size.width * scale, height: size.height * scale))
        }
        logCacheDirectory(fields.value(named: "cacheDirectory", as: URL.self))

        // Layers are main-actor state on macOS 27, and XPC calls arrive on a queue
        // of their own, so the surface is built, and the reply sent, on the main
        // thread. Both ends are logged, so a main thread that never runs shows.
        // Held by display and desktop-or-preview, not by the id's description:
        // that is only an address in this process. In 0.3 a desktop acquire and a
        // preview acquire arrived at the same address, and the preview's surface
        // replaced the desktop's. Found 2026-09-15 from the 0.3 log.
        let key = "display \(display.map { String($0) } ?? "unknown"), \(preview == true ? "preview" : "desktop")"
        nonisolated(unsafe) let send = reply
        probe("acquire: building the surface on the main thread")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                probe("acquire: on the main thread")
                guard let picture = ProbePicture.image, let still = ProbePicture.stillSample(of: picture) else {
                    probe("acquire: no picture to show")
                    send(nil, probeError(3, "no picture"))
                    return
                }
                guard let surface = RemoteSurface.make(size: size, scale: scale, display: display, still: still) else {
                    send(nil, probeError(4, "no remote context"))
                    return
                }
                guard let answer = RemoteSurface.reply(for: surface.contextID) else {
                    send(nil, probeError(5, "no reply object"))
                    return
                }
                Surfaces.keep(surface, for: key)
                probe("acquire: kept as \(key)")
                probe("acquire: replied with context \(surface.contextID)")
                send(answer, nil)

                // The fourth probe. The desktop asks the agent, after the reply,
                // so a slow agent never holds `WallpaperAgent` up; the preview
                // keeps the generated picture, so opening the pane spends no card.
                guard preview == false else { return }
                let pixels = CGSize(width: size.width * scale, height: size.height * scale)
                let contextID = surface.contextID
                DispatchQueue.global(qos: .utility).async {
                    AgentPicture.fetch(display: display, pixels: pixels) { image in
                        guard let image else {
                            probe("agent: \(key) keeps the generated picture")
                            return
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                Surfaces.show(image, for: key, contextID: contextID)
                            }
                        }
                    }
                }
            }
        }
    }

    func update(id: Any?, request: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("update", id, request)
        reply(nil)
    }

    /// Kept, not torn down: Phosphene found `WallpaperAgent` drops and re-acquires
    /// around every change, and tearing down on invalidate blanked the desktop.
    func invalidate(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("invalidate", id)
        reply(nil)
    }

    /// The third probe. The picture as an IOSurface at the desktop's size, for
    /// the export `WallpaperAgent` makes of the chosen wallpaper.
    func snapshot(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("snapshot", id)
        // Bisect, 2026-09-15: the desktop went gray in 0.3, with snapshots
        // answered. 0.3.1 answered nothing and showed the picture. 0.3.2 answers
        // again, with surfaces held by display rather than by the id's address.
        if !Self.answersSnapshots {
            probe("snapshot: not answered in this bisect build")
            reply(nil, nil)
            return
        }
        let remembered = DesktopSize.last
        let pixels = remembered ?? CGSize(width: 1920, height: 1080)
        // Since the fourth probe: whatever the desktop shows, the agent's
        // photograph once it has arrived.
        let shown = ShownPicture.desktop
        probe("snapshot: of \(shown == nil ? "the generated picture" : "the agent's photograph")")
        guard let picture = shown ?? ProbePicture.image, let surface = ProbePicture.surface(of: picture, pixels: pixels) else {
            probe("snapshot: no surface to send")
            reply(nil, probeError(6, "no surface"))
            return
        }
        guard let answer = SnapshotReply.make(surface: surface) else {
            reply(nil, probeError(7, "no snapshot reply"))
            return
        }
        probe(
            "snapshot: replied with a \(surface.width)x\(surface.height) IOSurface\(remembered == nil ? ", at the fallback size: no desktop acquire seen yet" : "")")
        reply(answer, nil)
    }

    // MARK: - Everything else, answered empty

    func addChoiceRequest(_ request: Any?, onBehalfOf process: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("addChoiceRequest", request, process)
        reply(nil, nil)
    }

    func removeChoiceRequest(_ request: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("removeChoiceRequest", request)
        reply(nil)
    }

    func selectedChoicesDidChange(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("selectedChoicesDidChange", id)
        reply(nil)
    }

    func invokeContextMenuAction(menuItemID: Any?, groupItemID: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("invokeContextMenuAction", menuItemID, groupItemID)
        reply(nil)
    }

    func isChoiceDownloaded(_ choice: Any?, reply: @escaping (Bool, (any Error)?) -> Void) {
        heard("isChoiceDownloaded", choice)
        reply(true, nil)
    }

    func download(choiceID: Any?, reply: @escaping ((any Error)?) -> Void) -> Progress? {
        heard("download", choiceID)
        reply(nil)
        return nil
    }

    func pauseDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("pauseDownload", choice)
        reply(nil)
    }

    func cancelDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("cancelDownload", choice)
        reply(nil)
    }

    func resumeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("resumeDownload", choice)
        reply(nil)
    }

    func removeDownload(_ choice: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("removeDownload", choice)
        reply(nil)
    }

    func migrateSelectedChoice(id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("migrateSelectedChoice", id)
        reply(nil, nil)
    }

    func migrate(from: Any?, to: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("migrate", from, to)
        reply(nil)
    }

    func skipShuffledContent(id: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("skipShuffledContent", id)
        reply(nil)
    }

    func canSkipShuffledContent(id: Any?, reply: @escaping (Bool, (any Error)?) -> Void) {
        heard("canSkipShuffledContent", id)
        reply(false, nil)
    }

    func handleDebugRequest(_ request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        heard("handleDebugRequest", request)
        reply(nil, nil)
    }

    func handleNotification(name: Any?, reply: @escaping ((any Error)?) -> Void) {
        heard("handleNotification", name)
        reply(nil)
    }
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
    /// Held for as long as the surface: the receiver is how the layer was
    /// handed its frame, and belongs to this synchronizer.
    let synchronizer: AVSampleBufferRenderSynchronizer
    let receiver: AVSampleBufferVideoRenderer.Receiver
    let contextID: UInt32

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
            probe("remote context: no CAContext class")
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
            probe("remote context: none created")
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
        // The macOS 27 way to hand a renderer a frame: a render synchronizer's
        // receiver. The sample buffer is this surface's alone and is not touched
        // again, which is what the unsafe initializer asks of it.
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let receiver = synchronizer.sampleBufferReceiver(adding: still.sampleBufferRenderer)
        let result = receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample))
        CATransaction.flush()

        probe("remote context \(contextID) holds the picture at \(Int(size.width))x\(Int(size.height)); enqueue result \(result)")
        return RemoteSurface(
            context: context, root: root, still: still, synchronizer: synchronizer, receiver: receiver,
            contextID: contextID)
    }

    /// A new still on the same layer, through the same receiver.
    @MainActor
    func show(_ image: CGImage) -> Bool {
        guard let sample = ProbePicture.stillSample(of: image) else {
            probe("remote context \(contextID): no sample buffer for the new picture")
            return false
        }
        let result = receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample))
        CATransaction.flush()
        probe("remote context \(contextID) now holds a \(image.width)x\(image.height) picture; enqueue result \(result)")
        return true
    }

    /// `WallpaperRemoteContextXPC` carrying the context id in its `box` ivar,
    /// which is how Phosphene answers. Fails closed if the class's layout is not
    /// the one expected, rather than writing past the instance.
    static func reply(for contextID: UInt32) -> AnyObject? {
        guard let replyClass = NSClassFromString("WallpaperRemoteContextXPC"),
            let created = class_createInstance(replyClass, 0)
        else {
            probe("reply: WallpaperRemoteContextXPC could not be created")
            return nil
        }
        guard let box = class_getInstanceVariable(replyClass, "box") else {
            probe("reply: WallpaperRemoteContextXPC has no box ivar")
            return nil
        }
        let offset = ivar_getOffset(box)
        guard offset >= 0, offset + MemoryLayout<UInt32>.size <= class_getInstanceSize(replyClass) else {
            probe("reply: box at offset \(offset) does not fit in \(class_getInstanceSize(replyClass)) bytes")
            return nil
        }
        let instance = created as AnyObject
        Unmanaged.passUnretained(instance).toOpaque().advanced(by: offset).storeBytes(of: contextID, as: UInt32.self)
        return instance
    }
}

/// The desktop's size in pixels, from the last `acquire` that was not a
/// preview — the size a snapshot is drawn at.
enum DesktopSize {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: CGSize?

    static var last: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func remember(_ pixels: CGSize) {
        lock.lock()
        stored = pixels
        lock.unlock()
    }
}

/// `WallpaperSnapshotXPC` carrying an IOSurface. Phosphene writes a retained
/// surface pointer at offset 8. The probe logs the class's ivars first, and
/// writes only if they show a pointer-sized field there; otherwise it fails
/// closed rather than writing into memory it cannot see.
enum SnapshotReply {
    static func make(surface: IOSurface) -> AnyObject? {
        guard let snapshotClass = NSClassFromString("WallpaperSnapshotXPC") else {
            probe("snapshot: WallpaperSnapshotXPC is not loaded")
            return nil
        }
        let instanceSize = class_getInstanceSize(snapshotClass)
        var count: UInt32 = 0
        var ivars: [(name: String, offset: Int, type: String)] = []
        if let list = class_copyIvarList(snapshotClass, &count) {
            for index in 0..<Int(count) {
                let ivar = list[index]
                ivars.append(
                    (
                        ivar_getName(ivar).map { String(cString: $0) } ?? "?",
                        ivar_getOffset(ivar),
                        ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
                    ))
            }
            free(list)
        }
        let listed =
            ivars.isEmpty
            ? "none listed" : ivars.map { "\($0.name) at \($0.offset), type \"\($0.type)\"" }.joined(separator: "; ")
        probe("snapshot: WallpaperSnapshotXPC is \(instanceSize) bytes; ivars: \(listed)")

        let offset = 8
        let fieldEnd = ivars.map(\.offset).filter { $0 > offset }.min() ?? instanceSize
        guard ivars.contains(where: { $0.offset == offset }),
            fieldEnd - offset >= MemoryLayout<UnsafeRawPointer>.size
        else {
            probe("snapshot: no pointer-sized field at offset \(offset); not writing")
            return nil
        }
        guard let created = class_createInstance(snapshotClass, 0) else {
            probe("snapshot: WallpaperSnapshotXPC could not be created")
            return nil
        }
        let instance = created as AnyObject
        let retained = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(instance).toOpaque().advanced(by: offset)
            .storeBytes(of: retained, as: UnsafeMutableRawPointer.self)
        return instance
    }
}

/// The acquire request's cache directory, and whether the sandboxed extension
/// can reach it. A count of what is inside, not the names: the contents are
/// `WallpaperAgent`'s.
func logCacheDirectory(_ directory: URL?) {
    guard let directory else {
        probe("acquire: no cacheDirectory in the request")
        return
    }
    let path = directory.path(percentEncoded: false)
    let scoped = directory.startAccessingSecurityScopedResource()
    defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: path)
        probe("acquire: cacheDirectory \(path), security scope \(scoped ? "granted" : "not granted"), \(entries.count) entries readable")
    } catch {
        probe(
            "acquire: cacheDirectory \(path), security scope \(scoped ? "granted" : "not granted"), not readable: \(error.localizedDescription)")
    }
}

/// Surfaces outlive the connection that asked for them; a context nobody holds
/// is freed, and the desktop goes blank.
enum Surfaces {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [String: RemoteSurface] = [:]

    static func keep(_ surface: RemoteSurface, for key: String) {
        lock.lock()
        held[key] = surface
        let count = held.count
        lock.unlock()
        probe("holding \(count) surface\(count == 1 ? "" : "s")")
    }

    /// Puts a picture on the surface held for `key`, if it is still the one the
    /// picture was asked for: `WallpaperAgent` may have acquired again meanwhile.
    @MainActor
    static func show(_ image: CGImage, for key: String, contextID: UInt32) {
        lock.lock()
        let surface = held[key]
        lock.unlock()
        guard let surface, surface.contextID == contextID else {
            probe("agent: \(key) was replaced before the picture arrived; not shown")
            return
        }
        if surface.show(image) { ShownPicture.remember(image) }
    }
}

/// What the desktop shows once the agent's photograph has arrived, for
/// `snapshot`. Nil while it still shows the generated picture.
enum ShownPicture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: CGImage?

    static var desktop: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func remember(_ image: CGImage) {
        lock.lock()
        stored = image
        lock.unlock()
    }
}

/// Everything `Mirror` can see inside a private request, flattened to dotted
/// paths, so one field can be found by name and the rest logged.
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
            // A `Data`'s bytes swamp the log line and hold nothing the probe reads.
            if child.value is Data { continue }
            walk(child.value, path: childPath, depth: depth - 1)
        }
    }

    func value<T>(named name: String, as _: T.Type) -> T? {
        fields.first { ($0.path == name || $0.path.hasSuffix(".\(name)")) && $0.value is T }?.value as? T
    }

    var summary: String {
        fields.isEmpty
            ? "none visible"
            : fields.prefix(80).map { "\($0.path): \(type(of: $0.value))" }.joined(separator: ", ")
    }

    /// The fields with their values, for small objects such as an id.
    var valuesSummary: String {
        fields.isEmpty
            ? "none visible"
            : fields.prefix(20).map { "\($0.path): \(type(of: $0.value)) = \(described($0.value))" }.joined(separator: ", ")
    }
}

func described(_ value: Any?) -> String {
    guard let value else { return "nil" }
    let text = String(describing: value)
    return text.count > 700 ? String(text.prefix(700)) + "…" : text
}

func probeError(_ code: Int, _ text: String) -> NSError {
    NSError(
        domain: "com.sydpolk.photogoround.wallpaper-probe", code: code,
        userInfo: [NSLocalizedDescriptionKey: text])
}
