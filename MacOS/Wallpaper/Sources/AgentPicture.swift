// Pictures from the agent. `Wallpaper Plan.md`, *What the fourth probe found* for
// the measurements this rests on.
//
// **The agent is the source of everything.** Syd, 2026-09-15: "we should just use
// the agent as the source of everything". The extension asks for a photograph and
// draws it; sources, the queue and the cache are the agent's, changed in the app
// or with `pgr_ctl`.
//
// The port is read through `ServicePort`, which tries the suite and then the
// plist — measured inside this sandbox on 2026-09-15, where both worked given the
// read-only exceptions in the entitlements.

import ColorSync
import CoreGraphics
import Foundation
import ImageIO
import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay

enum AgentPicture {
    /// What the agent's served line says, which is how the pane's wallpaper is
    /// told from the app's. See `Wallpaper Plan.md`, *Two wallpapers, told apart
    /// in the log*.
    ///
    /// **One name per slot.** Syd, 2026-09-15: "doesn't the agent log have the
    /// calling entity for the fetch?" It has whatever the client says, and until
    /// now both slots said `system-wallpaper` — so the desktop's card and the
    /// screen saver's were indistinguishable in the agent's log, and worse, they
    /// shared one consumer row: identity is `(kind, displayID)`, so two slots on
    /// one display counted as one surface and shared a shuffle position. The same
    /// mistake the extension made internally, one layer out.
    ///
    /// `ConsumerKind` is deliberately not an enum and the schema has no CHECK, so
    /// a new name needs nothing in the agent. See `Consumer.swift`.
    /// `system-wallpaper` and `system-screensaver`, beside the app's `wallpaper`
    /// and the saver's `screensaver`. The prefix says which host is drawing; the
    /// noun says which surface it is.
    static func consumer(for slot: Slot) -> String {
        slot == .desktop ? "system-wallpaper" : "system-screensaver"
    }

    /// This build's deployment only, since 2026-09-23, when each build got one:
    /// production in Release, development in Debug and Claude —
    /// `Deployment.current`. It asked development and then production until
    /// then, which in a Release build read the interval out of a development
    /// domain an older Release had left behind, ahead of the one the app writes.
    static let deployments: [Deployment] = [.current]

    struct Answer: Sendable {
        let image: CGImage
        let deployment: Deployment
        /// `X-PGR-Card`, which names the photograph in the agent's log and in
        /// the deck. Kept so the extension can say which picture it is showing,
        /// and remember it for the next preview.
        let card: String?
    }

    /// The display's UUID, spelled as the saver spells it,
    /// so the agent counts one consumer per display rather than per surface.
    static func displayUUID(_ display: UInt32?) -> String? {
        guard let display, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// **Longer than the agent's own worst case.** The agent fetches an original
    /// before it serves one, and its log says "up to 60 seconds" for that; a
    /// ten-second timeout here gave up at 21:55:37 on 2026-09-15 while the agent
    /// served the picture at :38, so two cards were dealt to a client that had
    /// already stopped listening and the desktop kept the mark. Ninety seconds is
    /// the agent's budget plus room to send the bytes.
    ///
    /// A wallpaper can afford to wait: nothing is on screen waiting for it except
    /// the picture it already has.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        return URLSession(configuration: configuration)
    }()

    /// Asks each deployment's agent in turn. A transport failure moves on, and
    /// so does a `401`, which is an agent that is not this user's; any other
    /// HTTP answer is final, since it came from this user's agent.
    static func fetch(display: UInt32?, pixels: CGSize, slot: Slot, done: @escaping @Sendable (Answer?) -> Void) {
        ask(deployments, at: 0, uuid: displayUUID(display), pixels: pixels, slot: slot, done: done)
    }

    private static func ask(
        _ deployments: [Deployment], at index: Int, uuid: String?, pixels: CGSize, slot: Slot,
        done: @escaping @Sendable (Answer?) -> Void
    ) {
        guard index < deployments.count else {
            wallpaperLog("no agent answered; the desktop keeps what it has")
            done(nil)
            return
        }
        let deployment = deployments[index]
        // The agent's own domain, asked for rather than spelled again: it
        // carries the build variant now, so a second copy of this expression
        // would send a Debug extension at the release agent's published port.
        let domain = MacHostEnvironment.preferenceDomain(for: deployment)
        let next: @Sendable () -> Void = {
            ask(deployments, at: index + 1, uuid: uuid, pixels: pixels, slot: slot, done: done)
        }

        // The suite first, the plist underneath — `ServicePort`'s own route, and
        // the sandbox is permitted both by the entitlements.
        let preferences = Preferences(suiteName: domain)
        let port: UInt16
        switch ServicePort.read(preferences) {
        case .published(let found, let origin):
            port = found
            // A standing fact, so it is said when it changes. It used to be
            // written on every wake. `Plans/Logging.md`, Phase 2.
            wallpaperLogWhenChanged("port", "port \(found) from the \(domain) \(origin.rawValue)")
        case .none:
            wallpaperLog("no port published in \(domain)")
            next()
            return
        case .unreadable(let reason):
            wallpaperLog("the port in \(domain) could not be read: \(reason)")
            next()
            return
        }

        // **Beside the port, by the same route.** Every request carries this
        // user's secret, and an agent refuses one that does not.
        // `Plans/Multi-user Support.md`.
        let secret: String
        switch ServicePort.readSecret(preferences) {
        case .published(let found, _):
            secret = found
        case .none:
            wallpaperLog("a port but no secret is published in \(domain)")
            next()
            return
        case .unreadable(let reason):
            wallpaperLog("the secret in \(domain) could not be read: \(reason)")
            next()
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/v1/next"
        let width = max(Int(pixels.width), 1)
        let height = max(Int(pixels.height), 1)
        var query = [URLQueryItem(name: "consumer", value: consumer(for: slot))]
        if let uuid { query.append(URLQueryItem(name: "display", value: uuid)) }
        query.append(URLQueryItem(name: "w", value: String(width)))
        query.append(URLQueryItem(name: "h", value: String(height)))
        components.queryItems = query
        guard let url = components.url else {
            wallpaperLog("no URL could be made for port \(port)")
            done(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(ServiceSecret.authorization(secret), forHTTPHeaderField: ServiceSecret.headerField)

        let started = ContinuousClock.now
        session.dataTask(with: request) { data, response, error in
            let elapsed = started.duration(to: .now)
            let milliseconds = elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            if let error {
                wallpaperLog("port \(port) in \(domain) unreachable after \(milliseconds) ms: \(error.localizedDescription)")
                next()
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bytes = data?.count ?? 0
            wallpaperLog(
                "asked \(domain) on \(port) for \(width)x\(height): \(status), \(bytes) bytes, \(milliseconds) ms")
            // **Not an answer from this user's agent**, so not final: whoever
            // holds that port refused this user's secret. Ask the next domain,
            // as for a port nothing answers on.
            guard status != 401 else {
                wallpaperLog("the agent on \(port) refused \(domain)'s secret; it is not this user's")
                next()
                return
            }
            guard status == 200, let data else {
                // 204 is an empty library or a queue turning over, and is an
                // answer: the desktop keeps the picture it has.
                done(nil)
                return
            }
            guard let image = decode(data, longestSide: max(width, height)) else {
                done(nil)
                return
            }
            let card = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-PGR-Card")
            done(Answer(image: image, deployment: deployment, card: card))
        }.resume()
    }

    /// Decoded at no more than the desktop's longest side, with the file's
    /// orientation applied.
    static func decode(_ data: Data, longestSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            wallpaperLog("the picture would not open as an image")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            wallpaperLog("the picture would not decode")
            return nil
        }
        return image
    }
}
