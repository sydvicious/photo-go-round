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

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        if SourceEndpoint.claims(request.path) {
            return await sources.route(request)
        }
        return await pictures.route(request)
    }
}
