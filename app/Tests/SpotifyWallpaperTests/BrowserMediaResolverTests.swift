import XCTest
@testable import SpotifyWallpaper

final class BrowserMediaResolverTests: XCTestCase {
    private func track(_ title: String = "Paint It, Black", artist: String = "The Rolling Stones") -> Track {
        Track(id: "test", title: title, artist: artist, album: "Aftermath", artworkURL: "",
              duration: 202, position: 20, isPlaying: true)
    }

    private func tab(_ title: String, _ url: String, active: Bool = false) -> BrowserMediaResolver.Tab {
        .init(title: title, url: url, active: active, audibleWindow: false)
    }

    func testMatchesMusicTabByTitleAndArtist() {
        let tabs = [
            tab("Home / X", "https://x.com/home", active: true),
            tab("Paint It, Black • The Rolling Stones • YouTube Music", "https://music.youtube.com/watch?v=test"),
        ]

        XCTAssertEqual(BrowserMediaResolver.match(track: track(), tabs: tabs)?.host, "music.youtube.com")
    }

    func testReturnsNonMusicHostSoPolicyCanRejectIt() {
        let tabs = [
            tab("Paint It, Black / X", "https://x.com/example/status/1"),
            tab("Inbox", "https://mail.example.com"),
        ]

        XCTAssertEqual(BrowserMediaResolver.match(track: track(), tabs: tabs)?.host, "x.com")
    }

    func testAbstainsWhenMatchingTabsDisagreeOnHost() {
        let tabs = [
            tab("Paint It, Black — The Rolling Stones", "https://music.youtube.com/watch?v=test"),
            tab("Paint It, Black — The Rolling Stones", "https://x.com/example/status/1", active: true),
        ]

        XCTAssertNil(BrowserMediaResolver.match(track: track(), tabs: tabs))
    }

    func testAbstainsWhenSeveralTabsDoNotMatchMetadata() {
        let tabs = [
            tab("Library", "https://music.youtube.com/library"),
            tab("A video", "https://x.com/example/status/1"),
        ]

        XCTAssertNil(BrowserMediaResolver.match(track: track(), tabs: tabs))
    }

    func testOneOpenTabIsTheBrowserSourceEvenWithCustomMetadata() {
        let tabs = [tab("My queue", "https://open.spotify.com/collection/tracks")]

        XCTAssertEqual(BrowserMediaResolver.match(track: track(), tabs: tabs)?.host, "open.spotify.com")
    }

    func testMatchingIgnoresCaseDiacriticsAndPunctuation() {
        let tabs = [
            tab("Beyoncé — Déjà Vu | TIDAL", "https://listen.tidal.com/album/1/track/2"),
            tab("News", "https://example.com"),
        ]

        XCTAssertEqual(BrowserMediaResolver.match(track: track("Deja Vu", artist: "Beyonce"), tabs: tabs)?.host,
                       "listen.tidal.com")
    }
}
