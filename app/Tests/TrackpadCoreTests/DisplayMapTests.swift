// The Mac-to-Wine coordinate scale: one factor for every screen, accepted only when the whole rectangle matches.
import CoreGraphics
import Testing
@testable import TrackpadCore

let mac = CGRect(x: 0, y: 0, width: 1512, height: 982)

@Test func retinaAndNot() {
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 3024, height: 1964), cgUnion: mac) == 2)
    #expect(DisplayMap.scale(hello: mac, cgUnion: mac) == 1)
}

@Test func negativeOriginAndStackedScreens() {
    let left = CGRect(x: -1920, y: 0, width: 3432, height: 1080)
    #expect(DisplayMap.scale(hello: CGRect(x: -3840, y: 0, width: 6864, height: 2160), cgUnion: left) == 2)
    let stacked = CGRect(x: 0, y: -1080, width: 1920, height: 2062)
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: -2160, width: 3840, height: 4124), cgUnion: stacked) == 2)
}

@Test func toleranceIsTheScale() {
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 3024, height: 1966), cgUnion: mac) == 2)
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 3024, height: 1967), cgUnion: mac) == nil)
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 1512, height: 983), cgUnion: mac) == 1)
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 1512, height: 984), cgUnion: mac) == nil)
    #expect(DisplayMap.scale(hello: CGRect(x: 3, y: 0, width: 3024, height: 1964), cgUnion: mac) == nil)   // origin off
}

@Test func otherFactorsRefused() {
    #expect(DisplayMap.scale(hello: CGRect(x: 0, y: 0, width: 2268, height: 1473), cgUnion: mac) == nil)  // ×1.5
}

@Test func toWineMultiplies() {
    #expect(DisplayMap.toWine(CGPoint(x: 100.4, y: -20.6), scale: 2) == WinePoint(x: 200, y: -42))   // the pixel that holds the point (floor)
    #expect(DisplayMap.toWine(CGPoint(x: 100.4, y: 20.6), scale: 1) == WinePoint(x: 100, y: 20))
}
