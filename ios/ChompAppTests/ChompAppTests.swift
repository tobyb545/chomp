import Foundation
import Testing
import UIKit
@testable import Chomp
import ChompKit

@Suite("Profile storage") @MainActor
struct ProfileStorage {
    @Test func olderProfileKeepsItsFieldsAndGetsNewDefaults() throws {
        // A profile saved before intro cards, map brightness, voice and invites existed.
        let old = #"{"id":"abc","name":"Sam","colorHex":"FF00AA","homeArea":"west-byfleet","onboarded":true,"privateMode":true,"soundOn":false,"hapticsOn":true,"useMiles":true,"trailStyle":"comet","privacyZones":[],"dismissedZoneSuggestions":[],"blockedPlayers":["x"],"mutedPlayers":[],"debugPro":false}"#
        let p = try JSONDecoder().decode(PlayerProfile.self, from: Data(old.utf8))
        #expect(p.name == "Sam" && p.onboarded && p.privateMode && !p.soundOn && p.useMiles && p.trailStyle == .comet)
        #expect(p.blockedPlayers == ["x"])
        #expect(!p.seenIntro, "existing players see the intro cards once")
        #expect(p.mapLook == .dusk && !p.voiceOn && p.voiceSplits && p.pendingInviteCode == nil)
    }

    @Test func aBadFieldDoesntResetTheRest() throws {
        let json = #"{"name":"Sam","onboarded":true,"mapLook":"neon","trailStyle":42}"#
        let p = try JSONDecoder().decode(PlayerProfile.self, from: Data(json.utf8))
        #expect(p.name == "Sam" && p.onboarded)
        #expect(p.mapLook == .dusk && p.trailStyle == .solid)
    }

    @Test func newFieldsRoundTrip() throws {
        var p = PlayerProfile()
        p.seenIntro = true; p.mapLook = .light; p.voiceOn = true; p.voiceSplits = false; p.pendingInviteCode = "ABC234"
        let back = try JSONDecoder().decode(PlayerProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func runsSavedBeforeTokensStillLoad() throws {
        let rec = RunRecord(id: UUID(), areaSlug: "world", startedAt: .now, endedAt: .now, distance: 1200, movingTime: 400,
                            source: .live, outcome: try JSONDecoder().decode(RunOutcome.self, from: Data(#"{"runID":"\#(UUID().uuidString)","captures":[],"points":0,"blockBonus":0,"blocksCompleted":[],"pelletsCollected":[],"frenzyWindows":[],"verdict":"accepted","flags":[],"conqueredTown":false}"#.utf8)),
                            splits: [], simulated: false, tokens: 42)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as! [String: Any]
        #expect(obj["tokens"] as? Int == 42)
        obj.removeValue(forKey: "tokens")
        let old = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.tokens == nil && old.distance == 1200)
    }
}

@Suite("Invites") @MainActor
struct Invites {
    @Test func codesAreNormalisedAndValidated() {
        #expect(InviteCode.normalise(" abc-234 ") == "ABC234")
        #expect(InviteCode.isValid("ABC234"))
        #expect(!InviteCode.isValid("ABC23"))      // too short
        #expect(!InviteCode.isValid("ABC2345"))    // too long
        #expect(!InviteCode.isValid("ABO234"))     // O looks like 0
        #expect(!InviteCode.isValid("AB1234"))     // 1 looks like I
        #expect(!InviteCode.isValid("abc234"))     // must be normalised first
    }

    @Test func serverErrorsBecomeReadable() {
        struct E: Error, CustomStringConvertible { let description: String }
        #expect(InviteView.friendly(E(description: #"PostgrestError(message: "chomp: you can't use your own code")"#)) == "you can't use your own code")
        #expect(InviteView.friendly(E(description: "chomp: code not found\nmore")) == "code not found")
    }
}

@Suite("Settings units") @MainActor
struct Units {
    @Test func distancesFormatInBothUnits() {
        #expect(formatDistance(1500, miles: false).contains("1.5"))
        #expect(formatDistance(1609.344, miles: true).contains("1.0"))
    }
}

@Suite("Coin colours") @MainActor
struct CoinColours {
    @Test func unclaimedSilverMineGold() {
        #expect(MapStyle.neutralCoin(.dusk) == "CDD3EA")
        #expect(MapStyle.neutralCoin(.light) == "9AA2BE")
        #expect(MapStyle.mineCoin(.dusk) == "FFC83D")
    }

    @Test func unclaimedCoinsAreDrawnSmallerAndCached() {
        let open = CoinIcon.render(colorHex: "CDD3EA", unclaimed: true)
        let mine = CoinIcon.render(colorHex: "FFC83D")
        #expect(open.size == mine.size, "same canvas, so map placement is unchanged")
        #expect(CoinIcon.render(colorHex: "FFC83D") === mine)
        // The unclaimed coin leaves the canvas corner area empty further in.
        func alpha(_ img: UIImage, _ x: Int, _ y: Int) -> UInt8 {
            let cg = img.cgImage!
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
            return px[3]
        }
        let edge = Int(CoinIcon.points * 3 * 0.2)  // 20% in from the left, mid-height
        let mid = Int(CoinIcon.points * 3 / 2)
        #expect(alpha(mine, edge, mid) > 200)
        #expect(alpha(open, edge, mid) < 60)
    }

    @Test func rivalsNeverLookGold() {
        #expect(MapStyle.rivalCoin("FFD600") == "FF3355")  // Sun
        #expect(MapStyle.rivalCoin("FF8A00") == "FF3355")  // Ember
        for keep in ["C6FF00", "00E5FF", "FF2BD6", "FF3355", "8B5CFF", "2BFFA8"] {
            #expect(MapStyle.rivalCoin(keep) == keep, "\(keep) keeps its colour")
        }
    }
}
