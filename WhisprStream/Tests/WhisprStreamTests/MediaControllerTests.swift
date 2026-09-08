import XCTest
@testable import WhisprStream

/// A scriptable backend that records calls and lets tests set play state.
private final class FakeMediaBackend: MediaPlayerBackend {
    var playing: Set<MediaApp>
    private(set) var paused: [MediaApp] = []
    private(set) var played: [MediaApp] = []

    init(playing: Set<MediaApp> = []) { self.playing = playing }

    func isPlaying(_ app: MediaApp) -> Bool { playing.contains(app) }

    func pause(_ app: MediaApp) {
        paused.append(app)
        playing.remove(app)
    }

    func play(_ app: MediaApp) {
        played.append(app)
        playing.insert(app)
    }
}

final class MediaControllerTests: XCTestCase {
    /// Runs `execute` work inline so assertions see the result immediately.
    private func makeController(
        backend: MediaPlayerBackend,
        enabled: Bool = true
    ) -> MediaController {
        MediaController(
            backend: backend,
            isEnabled: { enabled },
            execute: { work in work() }
        )
    }

    func testPausesOnlyPlayingAppsAndResumesExactlyThose() {
        let backend = FakeMediaBackend(playing: [.spotify])   // Music not playing
        let controller = makeController(backend: backend)

        controller.pauseForDictation()
        XCTAssertEqual(backend.paused, [.spotify])

        controller.resumeAfterDictation()
        XCTAssertEqual(backend.played, [.spotify])   // Music was never touched
    }

    func testDoesNothingWhenNothingIsPlaying() {
        let backend = FakeMediaBackend(playing: [])
        let controller = makeController(backend: backend)

        controller.pauseForDictation()
        controller.resumeAfterDictation()

        XCTAssertTrue(backend.paused.isEmpty)
        XCTAssertTrue(backend.played.isEmpty)   // never start music that wasn't playing
    }

    func testDisabledIsANoOp() {
        let backend = FakeMediaBackend(playing: [.music, .spotify])
        let controller = makeController(backend: backend, enabled: false)

        controller.pauseForDictation()
        XCTAssertTrue(backend.paused.isEmpty)
    }

    func testSecondPauseDoesNotStackWhileAlreadyPaused() {
        let backend = FakeMediaBackend(playing: [.music])
        let controller = makeController(backend: backend)

        controller.pauseForDictation()
        // A stray second start must not re-scan and (e.g.) pause a player the
        // user manually resumed mid-session.
        backend.playing.insert(.spotify)
        controller.pauseForDictation()

        XCTAssertEqual(backend.paused, [.music])
    }

    func testResumeWithoutPauseIsHarmless() {
        let backend = FakeMediaBackend(playing: [.music])
        let controller = makeController(backend: backend)

        controller.resumeAfterDictation()   // e.g. an error path with nothing paused
        XCTAssertTrue(backend.played.isEmpty)
    }

    func testResumeClearsStateSoASecondCycleWorks() {
        let backend = FakeMediaBackend(playing: [.music])
        let controller = makeController(backend: backend)

        controller.pauseForDictation()
        controller.resumeAfterDictation()

        // Second dictation, this time Spotify is the one playing.
        backend.playing = [.spotify]
        controller.pauseForDictation()
        XCTAssertEqual(backend.paused, [.music, .spotify])   // one from each cycle
    }
}
