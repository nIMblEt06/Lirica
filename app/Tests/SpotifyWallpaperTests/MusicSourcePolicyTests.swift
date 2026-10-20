import XCTest
@testable import SpotifyWallpaper

final class MusicSourcePolicyTests: XCTestCase {
    func testKnownMusicSitesAreAllowedButGeneralVideoAndSocialSitesAreNot() {
        XCTAssertTrue(MusicSourcePolicy.siteAllowed(host: "music.youtube.com"))
        XCTAssertTrue(MusicSourcePolicy.siteAllowed(host: "artist.bandcamp.com"))
        XCTAssertFalse(MusicSourcePolicy.siteAllowed(host: "youtube.com"))
        XCTAssertFalse(MusicSourcePolicy.siteAllowed(host: "x.com"))
    }

    func testWebPlayersJoinTheirNativeProvider() {
        XCTAssertEqual(MusicSourcePolicy.provider(forHost: "music.youtube.com"), .youtubeMusic)
        XCTAssertEqual(MusicSourcePolicy.provider(forHost: "open.spotify.com"), .spotify)
        XCTAssertEqual(MusicSourcePolicy.provider(forHost: "music.apple.com"), .appleMusic)
        XCTAssertEqual(MusicSourcePolicy.provider(forHost: "soundcloud.com"), .other)
    }

    func testKnownMusicAppsAndBrowsersStartOnButUnknownAppsStartOff() {
        XCTAssertTrue(MusicSourcePolicy.applicationAllowed(bundle: "com.spotify.client"))
        XCTAssertTrue(MusicSourcePolicy.applicationAllowed(bundle: "company.thebrowser.Browser"))
        XCTAssertFalse(MusicSourcePolicy.applicationAllowed(bundle: "com.apple.QuickTimePlayerX", name: "QuickTime Player"))
    }

    func testChromiumBrowsersShareOneSettingsGroup() {
        XCTAssertTrue(MusicSourcePolicy.isChromiumBrowser("company.thebrowser.Browser"))
        XCTAssertTrue(MusicSourcePolicy.isChromiumBrowser("com.google.Chrome"))
        XCTAssertTrue(MusicSourcePolicy.isChromiumBrowser("com.brave.Browser"))
        XCTAssertFalse(MusicSourcePolicy.isChromiumBrowser("com.apple.Safari"))
    }
}
