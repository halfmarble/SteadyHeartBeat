import Foundation

/// Everything SteadyHeartBeat can say.
///
/// This is the whole argument for pre-rendering: the app's speech is a CLOSED
/// vocabulary. It is derived from WorkoutManager._composeBpmAnnounce and the
/// literal cue strings, not invented — if a cue is added there it must be added
/// here. CorpusCoverageTests fails on a spoken cue with no clip, and a miss at
/// runtime logs `[kokoroclips] MISS`.
enum Corpus {
    /// The voice, in one place.
    ///
    /// Kokoro ships 28 English voices; SteadyHeartBeat speaks in exactly one,
    /// and the pre-rendered corpus is rendered in it — so this constant and
    /// `clips.json`'s "voice" field must agree or the app is asking for clips
    /// that were never made. `scripts/corpus_list.swift` and the renderer default to it.
    static let defaultVoice = "af_nova"

    /// Heart rates spoken as a number. Outside this range an earbud reading is
    /// far more likely a sensor glitch than a heart rate, so the app speaks
    /// `unclearReading` instead — it describes the READING, never the person.
    /// Saying a wrong number (a clamp) is worse than either.
    static let bpmRange = 25...250
    static let unclearReading = "Heart rate reading unclear"

    static let zonePhrases = ["below zone 1", "zone 1", "zone 2", "zone 3", "zone 4", "zone 5"]
    static let nudges = ["push!", "ease off!"]
    static let maxRound = 20

    /// Ascent milestones: WorkoutManager announces every +100 ft or +50 m, so
    /// each is one whole-phrase clip ("Climbed 300 feet") — stitching "Climbed"
    /// + number + unit sounds like three recordings, because it would be. Past
    /// the cap the cue falls through to the system voice; 5,000 ft / 1,500 m of
    /// climbing is far beyond any indoor or gym session.
    static let climbFeet = Array(stride(from: 100, through: 5_000, by: 100))
    static let climbMeters = Array(stride(from: 50, through: 1_500, by: 50))

    /// APPEND ONLY. A clip's id is its index here (`fixed_12`), so inserting
    /// or reordering renames every shipped clip after that point.
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
        "Welcome to SteadyHeartBeat. Your AirPods are connected. Tap start when you are ready.",
        "Welcome to SteadyHeartBeat. Put in your AirPods Pro to begin.",
        // Boxing round timer countdown and rest.
        "ten seconds",
        "three",
        "two",
        "one",
        "Rest",
        // HR-gated phases: entering, then leaving (reached or timed out).
        "Warm up. Keep moving",
        "Cool down. Keep moving lightly",
        "Rest. Keep moving",
        "Warmed up",
        "Let's begin",
        "Starting. Recovery incomplete",
        "All done",
        "Cool down complete",
        unclearReading,
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
        for f in climbFeet { out.append(("climbft_\(f)", "Climbed \(f) feet")) }
        for m in climbMeters { out.append(("climbm_\(m)", "Climbed \(m) meters")) }
        for (i, p) in fixedPhrases.enumerated() { out.append(("fixed_\(i)", p)) }
        return out
    }
}
