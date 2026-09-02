# Vendored Kokoro — Core ML only, CPU + ANE, never the GPU

Vendored 2026-08-28 from **github.com/mweinbach/kokoro-swift** (Apache-2.0),
which offers both an MLX/Metal backend and a segmented Core ML backend. Only the
Core ML half is here.

Model: **Kokoro-82M** by hexgrad, Apache-2.0, built on StyleTTS 2. Weights are
the pre-converted segments from huggingface.co/mweinbach/Kokoro-82M-Swift — no
PyTorch conversion step. G2P is **Misaki** (bundled with the upstream package);
**espeak-ng is never linked**, so nothing GPL enters this app.

## Why not just add the package

Upstream's `Package.swift` links `mlx-swift` unconditionally, and `KPipeline`
carries an `InferenceBackend` enum with an `.mlx(KModel)` case, so the Core ML
path cannot compile without dragging MLX — and therefore Metal — into the
binary. `SegmentedCoreMLModel.swift` itself imports only Accelerate, CoreML and
Foundation; the MLX entanglement is entirely in the pipeline and the voice
loader. So the CoreML half is lifted out and the MLX half is left behind.

## What is here, and what was changed

| File | Origin |
|---|---|
| `SegmentedCoreMLModel.swift` | upstream, **patched** (below) |
| `KokoroConfig.swift` | upstream, plus `KokoroOutput` |
| `Misaki/*.swift` | upstream `Packages/Misaki`, `Lexicon.swift` patched |
| `KokoroTTS.swift` | **new** — replaces `KPipeline` |
| `KokoroVoices.swift` | **new** — replaces `VoiceLoader` + `CoreMLVoiceAdapter` |

Patches, all verified by grepping the new text after writing:

1. **`aneConfiguration.computeUnits = .all` → `.cpuAndNeuralEngine`.** This is
   the whole reason the fork exists. `.all` lets Core ML schedule a segment on
   the GPU, and iOS refuses GPU work from a backgrounded app —
   `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`, measured
   on device 2026-08-28 (80 failures out of 80 attempts over 160 s). This app
   speaks while backgrounded, so a GPU-eligible segment is a silent cue in the
   middle of a workout. The `prosody` and `text_encoder` segments were already
   `.cpuOnly` upstream (they are LSTM-heavy); `albert` and `decoder` are the
   two that changed.
2. **`segmentURL(in:named:)` helper** — prefers the `.mlmodelc` Xcode compiles
   at build time, falling back to the raw `.mlpackage`. Upstream hardcodes
   `.mlpackage`, which costs a runtime compile of 226 MB on first launch.
3. **`KModel.Output` → `KokoroOutput`** (2 sites). `KModel` is the MLX model;
   its `Output` is plain Swift (`[Float]`, `[Int]`) and is rehomed unchanged
   into `KokoroConfig.swift`.
4. **`Bundle.module` → `Bundle.main`** in `Misaki/Lexicon.swift` (2 sites).
   Misaki compiles into the Runner target rather than as its own SPM module, so
   there is no module bundle; the four lexicon JSONs sit in the app bundle root.

`KokoroVoices.swift` is written rather than patched because upstream reads voice
packs into an `MLXArray` purely to take one row out of it — a reason to link
MLX that survives none of the reasons for linking MLX. It reads the `.npy`
directly and hands back an `MLMultiArray`.

Attribution for all of this — which files are modified copies, which are
verbatim, and which replace upstream types — is in the repository's `NOTICE`,
and each file now carries the same statement in its own header. That is what
Apache 2.0 section 4(b) asks for, and it is what the public repo publishes.

## The Core ML port is the LOW-QUALITY path (measured 2026-09-01)

There is a second Swift implementation of Kokoro inference — **KokoroSwift**
(github.com/mlalma/kokoro-ios), which runs **MLX** against the original
`kokoro-v1_0.safetensors` rather than converting to Core ML. Same model, same
voices, same 24 kHz. Rendering identical text through both, `af_nova`:

| band | this (Core ML) | KokoroSwift/MLX |
|---|---|---|
| 2-4 kHz | -53.0 dB | **-32.2 dB** |
| 4-6 kHz | -46.8 dB | **-34.0 dB** |
| 6-8 kHz | -38.9 dB | **-31.7 dB** |

2-6 kHz carries consonants and the upper formants. Being 20 dB down there is the
"robotic, barely human" quality the founder reported, and it survives every other
fix: it is not the AAC bitrate, not ANE float16 (CPU-only sounds the same), not
phoneme chunking (every cue fits one chunk), not the voice-pack loader (matches
numpy exactly), and not the local `--max-tokens 64` re-conversion (identical to
the published 512-token segments to 0.1 dB). Those were all checked, and each
false lead cost a round of the founder's time.

**So the shipped corpus is rendered offline with KokoroSwift/MLX**, on a Mac,
by tooling kept outside this repo. The clips are the product; this Core ML path
is not what produced them.
This Core ML vendoring now serves only tier 2, live synthesis of text outside the
corpus — which is text the app never speaks. Deleting it would remove 234 MB from
the bundle and this whole directory with it; that decision is open.

## Rules

- **Never reintroduce `.all`.** If a future segment needs the GPU it does not
  belong in this app. `KokoroComputeUnitsTests` (in `ios/RunnerTests/`) pins
  this: it scans every `computeUnits =` under `ios/Runner/` and fails on
  anything but `.cpuOnly` / `.cpuAndNeuralEngine`, and it fails on an
  `MLModelConfiguration()` left at its default (which is `.all`). It reads
  source rather than calling the code because both decisions sit inside
  methods that cannot run without the gitignored model segments.
- Assets live in `../KokoroAssets/`. The Core ML segments and voice packs
  (234 MB) are **gitignored** and are built by `ios/get-kokoro-coreml.sh`; the
  pre-rendered clips (`KokoroClips/`, 5.2 MB) are **tracked**, because they are
  the app's voice rather than a regenerable render. A fresh clone or worktree
  must still run the script before building — the Xcode project references the
  gitignored paths and the build fails without them.
- If upstream ever ships a Core ML-only product with a compute-units parameter,
  delete this directory and depend on the package.
