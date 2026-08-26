import Foundation

/// Which endpoint answers.
///
/// A type rather than a closure in `RunCommand` so that the dispatch is
/// something a test can hold: "a `POST` to `/v1/sources` does not reach the
/// picture endpoint" is a claim about this and about nothing else.
///
/// **Anything unclaimed goes to the pictures.** That endpoint already owns "no
/// such endpoint" and "only GET is served", and it already reports both through
/// the request log a person is watching — so the fallback keeps one account of
/// what arrived rather than two that have to be read together.
struct Router {
    let pictures: PictureEndpoint
    let sources: SourceEndpoint
    let photos: PhotosEndpoint

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        if SourceEndpoint.claims(request.path) {
            return await sources.route(request)
        }
        // **Claims the whole `/v2/photos` prefix**, not just the one route it
        // serves, so a mistyped path under it is answered by the endpoint that
        // knows what belongs there rather than by the pictures.
        if PhotosEndpoint.claims(request.path) {
            return await photos.route(request)
        }
        return await pictures.route(request)
    }
}
