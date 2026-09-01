#!/bin/zsh
# Build ios/Runner/KokoroAssets/ — the live Core ML tier.
#
# 234 MB, gitignored. Run once per fresh clone or worktree BEFORE building; the
# Xcode project references these paths and the build fails without them. The
# 5.2 MB of pre-rendered clips are tracked and need none of this — the app
# speaks without ever running it. This is only for tier 2, live synthesis of
# text outside the corpus.
#
# WHY IT CONVERTS RATHER THAN DOWNLOADS. The published segments are built at
# max_tokens=512, and at that size Kokoro's prosody segment is an LSTM unrolled
# into 111,733 MIL operations. Core ML's on-device Espresso AOT compile over
# that graph did not finish in 40 minutes on an iPhone 16 Pro Max. Re-converting
# at --max-tokens 64 cuts it to 35,573 ops and 195 s, with byte-comparable audio
# for cues of this length (same durations, same peaks). SteadyHeartBeat's
# longest cue is nowhere near 64 tokens.
#
# Model: Kokoro-82M by hexgrad, Apache-2.0. Converter: mweinbach/kokoro-swift,
# Apache-2.0. G2P: Misaki (bundled there) — espeak-ng is never used.
set -eu

OUT="$(cd "$(dirname "$0")" && pwd)/Runner/KokoroAssets"
WORK="${KOKORO_WORK:-${TMPDIR:-/tmp}/kokoro-build}"
JOBS="$WORK/kokoro-swift"
mkdir -p "$OUT/KokoroVoices" "$WORK"

HF_KOKORO="https://huggingface.co/hexgrad/Kokoro-82M/resolve/main"
HF_SWIFT="https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main"
MISAKI_RAW="https://raw.githubusercontent.com/mweinbach/kokoro-swift/main/Packages/Misaki/Sources/Misaki/Resources"

get() {  # url dest
  [ -s "$2" ] && { echo "  have $(basename "$2")"; return; }
  mkdir -p "$(dirname "$2")"
  curl -sfL "$1" -o "$2" || { echo "  FAILED $1" >&2; exit 1; }
  echo "  got  $(basename "$2")  ($(du -h "$2" | cut -f1))"
}

# ── things the app needs regardless of how the models are made ───────────────
echo "== config + Misaki lexicons =="
get "$HF_SWIFT/config.json" "$OUT/kokoro_config.json"
for lex in us_gold us_silver gb_gold gb_silver; do
  get "$MISAKI_RAW/$lex.json" "$OUT/$lex.json"
done

echo "== English voices (af/am/bf/bm) =="
curl -sL "https://huggingface.co/api/models/mweinbach/Kokoro-82M-Swift/tree/main?recursive=1" \
| python3 -c "
import json,sys
for f in json.load(sys.stdin):
    p=f.get('path',''); n=p.split('/')[-1]
    if p.startswith('MLX_GPU/voices/') and n.endswith('.npy') \
       and n[:2] in ('af','am','bf','bm') and not n.startswith('._'):
        print(p)" \
| while read -r v; do get "$HF_SWIFT/$v" "$OUT/KokoroVoices/$(basename "$v")"; done

# ── the four Core ML segments ────────────────────────────────────────────────
if [ "${1:-}" = "--prebuilt-512" ]; then
  echo "== prebuilt 512-token segments (NO conversion needed, but see the note"
  echo "   at the top: these take minutes-to-never to load on device) =="
  for seg in albert decoder prosody text_encoder; do
    B="CoreML_ANE/segmented/$seg.mlpackage"
    get "$HF_SWIFT/$B/Manifest.json"                            "$OUT/$seg.mlpackage/Manifest.json"
    get "$HF_SWIFT/$B/Data/com.apple.CoreML/model.mlmodel"      "$OUT/$seg.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    get "$HF_SWIFT/$B/Data/com.apple.CoreML/weights/weight.bin" "$OUT/$seg.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  done
  echo "== done (512-token): $(du -sh "$OUT" | cut -f1) =="
  exit 0
fi

if [ -d "$OUT/prosody.mlpackage" ]; then
  echo "== segments already present — delete $OUT/*.mlpackage to rebuild =="
  echo "== done: $(du -sh "$OUT" | cut -f1) =="
  exit 0
fi

echo "== converting at --max-tokens 64 (this takes ~15 min and ~4 GB of pip) =="

# coremltools' compiled BlobWriter has no wheel for Python 3.13+; 3.9 (system
# python3 on macOS) works. A 3.14 venv fails at save() with "BlobWriter not
# loaded", which reads like a bug in the script and is not.
PY=/usr/bin/python3
VENV="$WORK/venv"
[ -d "$VENV" ] || "$PY" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet coremltools torch transformers loguru munch scipy

get "$HF_KOKORO/kokoro-v1_0.pth" "$WORK/Kokoro-82M/kokoro-v1_0.pth"
get "$HF_KOKORO/config.json"     "$WORK/Kokoro-82M/config.json"

[ -d "$JOBS" ] || git clone --depth 1 https://github.com/mweinbach/kokoro-swift "$JOBS"

# The converter expects the Kokoro python package at a path relative to its own
# repo root; upstream never published that directory, so supply it.
ORIG="$(cd "$JOBS/Scripts" && "$VENV/bin/python" -c "
from pathlib import Path; print(Path('.').resolve().parents[2] / 'python_originals/kokoro_py')")"
if [ ! -d "$ORIG/kokoro" ]; then
  mkdir -p "$ORIG"
  [ -d "$WORK/kokoro-py" ] || git clone --depth 1 https://github.com/hexgrad/kokoro "$WORK/kokoro-py"
  "$VENV/bin/python" -c "
import shutil, sys; shutil.copytree('$WORK/kokoro-py/kokoro', '$ORIG/kokoro', dirs_exist_ok=True)"
fi

(cd "$JOBS" && "$VENV/bin/python" Scripts/convert_to_coreml_segmented.py \
    --config "$WORK/Kokoro-82M/config.json" \
    --checkpoint "$WORK/Kokoro-82M/kokoro-v1_0.pth" \
    --output-dir "$WORK/coreml_t64" \
    --segmented-output-dir "$WORK/coreml_t64/segmented" \
    --max-tokens 64)

"$VENV/bin/python" -c "
import shutil, pathlib
src = pathlib.Path('$WORK/coreml_t64/segmented'); dst = pathlib.Path('$OUT')
for seg in ('albert','decoder','prosody','text_encoder'):
    d = dst / f'{seg}.mlpackage'
    if d.exists(): shutil.rmtree(d)
    shutil.copytree(src / f'{seg}.mlpackage', d)
    print('  installed', d.name)"

echo "== done: $(du -sh "$OUT" | cut -f1) =="
