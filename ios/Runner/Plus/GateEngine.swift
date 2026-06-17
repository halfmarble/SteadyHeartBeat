import Foundation

// PUBLIC-EXPORT STUB — the free core ships no HR-gate engine. The Plus module
// (paid tier) provides a real implementation of GateEngineProtocol here in the
// private repo; with NoGateEngine every enable is false, so the gated branches
// in WorkoutManager are unreachable and the boxing round timer is the plain
// fixed-time timer. Same path and filename in both repos, so project.pbxproj
// is identical.
func makeGateEngine() -> GateEngineProtocol { NoGateEngine() }
