import Foundation

/// Everything SteadyHeartBeat can say.
///
/// This is the whole argument for pre-rendering: the app's speech is a CLOSED
/// vocabulary. It is derived from WorkoutManager._composeBpmAnnounce and the
/// literal cue strings, not invented — if a cue is added there it must be added
/// here, and `KokoroClips.unmapped` on the Swift side reports anything the app
/// asks for that was not rendered.
enum Corpus {
    /// The voice, in one place.
    ///
    /// Kokoro ships 28 English voices; SteadyHeartBeat speaks in exactly one,
    /// and the pre-rendered corpus is rendered in it — so this constant and
    /// `clips.json`'s "voice" field must agree or the app is asking for clips
    /// that were never made. `scripts/kokocli.swift -corpus` defaults to it for that reason.
    static let defaultVoice = "af_nova"

    /// Plausible announced heart rates. Below 30 or above 220 the app has
    /// bigger problems than pronunciation.
    static let bpmRange = 30...220

    static let zonePhrases = ["below zone 1", "zone 1", "zone 2", "zone 3", "zone 4", "zone 5"]
    static let nudges = ["push!", "ease off!"]
    static let maxRound = 20

    static let fixedPhrases = [
        "Monitoring heart rate",
        "Now monitoring in the background",
        "Workout monitoring stopped",
        "Workout complete",
        "Heart rate signal lost",
        "Forced to background",
        "Connecting to your AirPods. Please stand by.",
        "Connecting",
        "feet",
        "meters",
        "Climbed",
    ]

    /// (clip id, text to synthesize). The id is what the app looks up.
    static func all() -> [(id: String, text: String)] {
        var out: [(String, String)] = []
        for n in bpmRange {
            // Two renderings of every number: bare (no zone coaching) and with
            // the trailing comma the app appends before a zone phrase. The
            // comma is not cosmetic — it is the falling intonation and the beat
            // of silence that make "142, zone 4" sound like one sentence.
            out.append(("num_\(n)", "\(n)"))
            out.append(("numc_\(n)", "\(n),"))
        }
        for (i, z) in zonePhrases.enumerated() {
            out.append(("zone_\(i)", z))
            out.append(("zonec_\(i)", "\(z),"))
        }
        for (i, n) in nudges.enumerated() { out.append(("nudge_\(i)", n)) }
        for r in 1...maxRound { out.append(("round_\(r)", "Round \(r)")) }
        for (i, p) in fixedPhrases.enumerated() { out.append(("fixed_\(i)", p)) }
        return out
    }
}
