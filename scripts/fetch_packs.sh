#!/usr/bin/env bash
# Downloads the bundled Mechvibes packs, byte-identical, from the upstream
# MIT-licensed repo https://github.com/hainguyents13/mechvibes, pinned to one commit.
# Display names and order live in Resources/SoundPacks/packs.json (ours), so the
# upstream config.json files stay unmodified. Pack list inspired by Clacky's
# scripts/fetch_default_packs.sh (MIT, https://github.com/jasonzh0/Clacky).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/SoundPacks"
COMMIT="326252a13e7bef4f1c35d08ef0189b5af6f8ba02"
UPSTREAM="https://raw.githubusercontent.com/hainguyents13/mechvibes/$COMMIT/src/audio"

FILES=(
  cherrymx-blue-pbt/config.json cherrymx-blue-pbt/sound.ogg
  cherrymx-brown-pbt/config.json cherrymx-brown-pbt/sound.ogg
  topre-purple-hybrid-pbt/config.json topre-purple-hybrid-pbt/sound.ogg
  eg-oreo/config.json eg-oreo/oreo.ogg
  holy-pandas/config.json holy-pandas/LICENSE holy-pandas/README.md
  holy-pandas/BACKSPACE.mp3 holy-pandas/ENTER.mp3 holy-pandas/SPACE.mp3
  holy-pandas/GENERIC_R0.mp3 holy-pandas/GENERIC_R1.mp3 holy-pandas/GENERIC_R2.mp3
  holy-pandas/GENERIC_R3.mp3 holy-pandas/GENERIC_R4.mp3
  holy-pandas/release/BACKSPACE.mp3 holy-pandas/release/ENTER.mp3
  holy-pandas/release/GENERIC.mp3 holy-pandas/release/SPACE.mp3
)

for f in "${FILES[@]}"; do
  mkdir -p "$DEST/$(dirname "$f")"
  if [[ ! -s "$DEST/$f" ]]; then
    curl -fsSL "$UPSTREAM/$f" -o "$DEST/$f"
    echo "fetched $f"
  fi
done
curl -fsSL "https://raw.githubusercontent.com/hainguyents13/mechvibes/$COMMIT/LICENSE" -o "$DEST/LICENSE-mechvibes"
echo "packs in $DEST (mechvibes@${COMMIT:0:7})"

# kbsim (https://github.com/tplai/kbsim, MIT, © Thomas Lai): every switch with press and release
# recordings, audio byte-identical, pinned commit. Holy Pandas is skipped: the Mechvibes pack
# above is the same recordings. config.json is ours (Mechvibes v2 format). kbsim's GENERIC_R0…R4
# are per keyboard row (R0 = F-row … R4 = bottom rows), which SoundPackLoader maps by row.
KBSIM="ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4"
KBURL="https://raw.githubusercontent.com/tplai/kbsim/$KBSIM"
curl -fsSL "$KBURL/LICENSE.md" -o "$DEST/LICENSE-kbsim"
for sw in mxbrown mxblack mxblue cream boxnavy blackink redink turquoise alpaca topre bluealps buckling; do
  d="$DEST/kbsim-$sw"
  mkdir -p "$d/press" "$d/release"
  files=(press/GENERIC_R0 press/GENERIC_R1 press/GENERIC_R2 press/GENERIC_R3 press/GENERIC_R4 release/GENERIC)
  [[ $sw == mxblue ]] || files+=(press/SPACE press/ENTER press/BACKSPACE release/SPACE release/ENTER release/BACKSPACE)
  for f in "${files[@]}"; do
    [[ -s "$d/$f.mp3" ]] || { curl -fsSL "$KBURL/src/assets/audio/$sw/$f.mp3" -o "$d/$f.mp3"; echo "fetched kbsim/$sw/$f.mp3"; }
  done
  cp "$DEST/LICENSE-kbsim" "$d/LICENSE"
  if [[ $sw == mxblue ]]; then special=""; else special='
    "14": "press/BACKSPACE.mp3", "14-up": "release/BACKSPACE.mp3",
    "28": "press/ENTER.mp3", "28-up": "release/ENTER.mp3",
    "57": "press/SPACE.mp3", "57-up": "release/SPACE.mp3"'; fi
  cat > "$d/config.json" <<JSON
{
  "id": "kbsim-$sw",
  "name": "kbsim $sw",
  "key_define_type": "multi",
  "sound": "press/GENERIC_R{0-4}.mp3",
  "soundup": "release/GENERIC.mp3",
  "defines": {$special
  },
  "version": 2
}
JSON
  printf 'Audio from https://github.com/tplai/kbsim (src/assets/audio/%s) at commit %s, unmodified.\nMIT License, (c) Thomas Lai, see LICENSE. config.json written by Clackwise.\n' "$sw" "$KBSIM" > "$d/README.md"
done
echo "kbsim packs in $DEST (kbsim@${KBSIM:0:7})"
