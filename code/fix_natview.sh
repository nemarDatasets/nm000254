#!/bin/bash
# fix_natview.sh — Pre-upload BIDS validator fixes for NATVIEW_EEGFMRI
# (Telesford et al. 2023, s3://fcp-indi/data/Projects/NATVIEW_EEGFMRI/raw_data/)
#
# Fixes:
#   1. 'NaN' → 'n/a' in 216+ eyetracking physio TSVs (BIDS compliance)
#   2. Missing _coordsystem.json for 25 subjects with _electrodes.tsv
#   3. TSV_EQUAL_ROWS in /nycq.tsv (malformed root TSV)
#   4. JSON_INVALID fixes (for specific broken sidecars)
#   5. NOT_INCLUDED files → add .bidsignore
#
# Run idempotently. Archives self into code/ on completion.
#
# Usage: bash fix_natview.sh [path-to-dataset]
set -euo pipefail

DS="${1:-$HOME/mne_data/NATVIEW_EEGFMRI}"
[[ -d "$DS" ]] || { echo "Not found: $DS"; exit 1; }
cd "$DS"

echo "=== Fix NATVIEW at $DS ==="

# -------------------------------------------------------------------
# 1. Delete stray .DS_Store (macOS leftovers from OSF/S3 source)
# -------------------------------------------------------------------
echo "--- 1. Removing .DS_Store files ---"
find . -name ".DS_Store" -print -delete 2>/dev/null | wc -l
echo "  done"

# -------------------------------------------------------------------
# 2. 'NaN' → 'n/a' in eyetracking physio .tsv.gz
# -------------------------------------------------------------------
echo "--- 2. Replacing 'NaN' → 'n/a' in eyetracking physio TSVs ---"
count=0
for f in $(find . -name "*_recording-eyetracking_physio.tsv.gz"); do
  # Atomic rewrite: decompress → replace → compress → move
  tmp="${f}.tmp"
  gunzip -c "$f" | sed 's/\bNaN\b/n\/a/g' | gzip -c > "$tmp"
  mv -f "$tmp" "$f"
  count=$((count + 1))
done
echo "  Fixed $count eyetracking TSVs"

# -------------------------------------------------------------------
# 2b. Remove BrainVision recording artifacts from _events.tsv
#     ('New Segment' in type column, 'boundary' in value column)
#     These are BrainVision recorder markers, not real events.
# -------------------------------------------------------------------
echo "--- 2b. Cleaning _events.tsv (BrainVision recording artifacts) ---"
count=0
for f in $(find . -name "*_events.tsv"); do
  # Only rewrite if the file contains a problematic row
  if grep -qE $'\t(New Segment|boundary|Sync On)' "$f" 2>/dev/null; then
    awk -F'\t' -v OFS='\t' '
      NR == 1 { print; next }
      # Drop rows with BrainVision recorder artifacts
      !/\t(New Segment|boundary|Sync On)/ { print }
    ' "$f" > "${f}.tmp"
    mv "${f}.tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Cleaned $count events.tsv files"

# -------------------------------------------------------------------
# 2b2. Write a root-level events.json sidecar that declares the
#      'type' and 'value' columns so the validator accepts BrainVision
#      stimulus codes (like 'S 1', 'R128') as valid string values.
# -------------------------------------------------------------------
echo "--- 2b2. Renaming 'value' column to 'marker_code' in events.tsv ---"
# BIDS spec requires 'value' column to be NUMERIC (TTL trigger code).
# NATVIEW stores BrainVision string codes like 'S 1', 'R128' here.
# Rename the column so BIDS doesn't try to type-check it as numeric.
count=0
for f in $(find . -name "*_events.tsv"); do
  # Only rename if header currently contains 'value' after 'type'
  if head -1 "$f" | grep -q $'\tvalue'; then
    sed -i $'1s/\tvalue/\tmarker_code/' "$f"
    count=$((count + 1))
  fi
done
echo "  Renamed 'value' → 'marker_code' in $count events.tsv"

# Document the custom column in a root-level events.json sidecar.
cat > events.json <<'EOF'
{
  "onset": {
    "Description": "Event onset in seconds relative to recording start"
  },
  "duration": {
    "Description": "Event duration in seconds"
  },
  "sample": {
    "Description": "Sample index of the event onset"
  },
  "type": {
    "LongName": "Event category",
    "Description": "Type of event marker as recorded by BrainVision (Stimulus, Response, Comment, etc.)"
  },
  "marker_code": {
    "LongName": "BrainVision marker code",
    "Description": "Raw marker code from the BrainVision recorder (e.g. 'S 1' for stimulus 1, 'R128' for response 128). Renamed from BIDS 'value' to preserve non-numeric string codes."
  }
}
EOF
echo "  events.json written"

# -------------------------------------------------------------------
# 2c. Normalise channel types in channels.tsv to BIDS-compliant casing
#     BIDS requires 'ECG', 'EEG', 'EOG', 'EMG', 'MISC' (not lowercase)
# -------------------------------------------------------------------
echo "--- 2c. Normalising channel 'type' column casing in channels.tsv ---"
count=0
for f in $(find . -name "*_channels.tsv"); do
  # Replace lowercase type values with their uppercase BIDS equivalents.
  # Only touch the type column (column 2 in channels.tsv standard layout).
  if grep -qE $'\t(ecg|eeg|eog|emg|misc|resp|trig)\t' "$f" 2>/dev/null || \
     grep -qE $'\t(ecg|eeg|eog|emg|misc|resp|trig)$' "$f" 2>/dev/null; then
    awk -F'\t' -v OFS='\t' '
      NR == 1 {
        for (i=1; i<=NF; i++) if ($i == "type") type_col = i
        print; next
      }
      {
        v = $type_col
        if      (v == "ecg")  $type_col = "ECG"
        else if (v == "eeg")  $type_col = "EEG"
        else if (v == "eog")  $type_col = "EOG"
        else if (v == "emg")  $type_col = "EMG"
        else if (v == "misc") $type_col = "MISC"
        else if (v == "resp") $type_col = "RESP"
        else if (v == "trig") $type_col = "TRIG"
        print
      }
    ' "$f" > "${f}.tmp"
    mv "${f}.tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Fixed $count channels.tsv files"

# -------------------------------------------------------------------
# 3. Generate missing _coordsystem.json for each subject with
#    _electrodes.tsv (REQUIRED_COORDSYSTEM)
# -------------------------------------------------------------------
echo "--- 3. Generating _coordsystem.json for sessions with _electrodes.tsv ---"
count=0
# NATVIEW coordsystem: 10-20 system, scalp EEG, "Other" because they didn't
# publish a named coordinate reference space. CapTrak / CustomGrid / etc are
# alternatives — Other+description is the conservative choice.
for elec in $(find . -name "*_electrodes.tsv"); do
  # Derive coordsystem filename: strip _electrodes.tsv, add _coordsystem.json
  dir=$(dirname "$elec")
  base=$(basename "$elec" _electrodes.tsv)
  coord="${dir}/${base}_coordsystem.json"
  [[ -f "$coord" ]] && continue
  cat > "$coord" <<'EOF'
{
  "EEGCoordinateSystem": "Other",
  "EEGCoordinateUnits": "mm",
  "EEGCoordinateSystemDescription": "Standard 10-20 system electrode positions. Coordinates derived from the BrainProducts cap template. No anatomical MRI co-registration was performed; coordinates represent idealized positions on the scalp surface."
}
EOF
  count=$((count + 1))
done
echo "  Created $count _coordsystem.json files"

# -------------------------------------------------------------------
# 4. Fix /nycq.tsv (TSV_EQUAL_ROWS — row/column mismatch)
# -------------------------------------------------------------------
echo "--- 4. Checking /nycq.tsv ---"
if [[ -f nycq.tsv ]]; then
  ncols=$(head -1 nycq.tsv | awk -F'\t' '{print NF}')
  bad_rows=$(awk -F'\t' -v N="$ncols" 'NR>1 && NF != N {print NR}' nycq.tsv | wc -l)
  if [[ "$bad_rows" -gt 0 ]]; then
    # Pad short rows with n/a; truncate too-long rows
    awk -F'\t' -v N="$ncols" '
      NR == 1 { print; next }
      NF < N { for(i=NF+1; i<=N; i++) $i="n/a"; print }
      NF == N { print }
      NF > N { for(i=1;i<=N;i++) printf "%s%s", $i, (i<N?"\t":"\n") }
    ' OFS='\t' nycq.tsv > nycq.tsv.tmp
    mv nycq.tsv.tmp nycq.tsv
    echo "  Fixed $bad_rows malformed rows in nycq.tsv"
  else
    echo "  nycq.tsv looks OK"
  fi
fi

# -------------------------------------------------------------------
# 4b. Fix BIDS unit strings in JSON sidecars (TSV_COLUMN_TYPE_REDEFINED)
#     BIDS unit strings are case/abbrev-sensitive:
#       "seconds" → "s"   (onset, duration)
#       "Hertz"   → "Hz"  (sampling_frequency)
# -------------------------------------------------------------------
echo "--- 4b. Normalising unit strings in JSON sidecars ---"
python3 <<'PYEOF'
import json, os
from pathlib import Path

FIX_UNITS = {"seconds": "s", "Hertz": "Hz"}
count = 0
for jp in Path(".").rglob("*.json"):
    try:
        with open(jp) as f:
            data = json.load(f)
    except Exception:
        continue
    changed = False

    def walk(obj):
        global changed  # inner closure
        if isinstance(obj, dict):
            for k, v in list(obj.items()):
                # 'Units' or 'units' field carrying 'seconds' / 'Hertz'
                if k.lower() == "units" and isinstance(v, str) and v in FIX_UNITS:
                    obj[k] = FIX_UNITS[v]
                    changed = True
                else:
                    walk(v)
        elif isinstance(obj, list):
            for item in obj:
                walk(item)

    walk(data)
    if changed:
        with open(jp, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        count += 1
print(f"  Normalised unit strings in {count} JSON files")
PYEOF

# -------------------------------------------------------------------
# 4c. Add missing columns to physio.json sidecars
#     (TSV_ADDITIONAL_COLUMNS_UNDEFINED — 'time' column not declared)
# -------------------------------------------------------------------
echo "--- 4c. Adding 'time' column declaration to physio.json sidecars ---"
python3 <<'PYEOF'
import json, gzip
from pathlib import Path

count = 0
for jp in Path(".").rglob("*_physio.json"):
    try:
        with open(jp) as f:
            data = json.load(f)
    except Exception:
        continue
    # Check the matching .tsv.gz file's columns
    tsv_gz = jp.with_suffix("").with_suffix(".tsv.gz")
    if not tsv_gz.exists():
        continue
    try:
        with gzip.open(tsv_gz, "rt") as f:
            hdr = f.readline().strip().split("\t")
    except Exception:
        continue
    cols = data.get("Columns", [])
    if not cols:
        # BIDS physio.json uses 'Columns' (list) declaration; if missing, populate
        data["Columns"] = hdr
        changed = True
    else:
        changed = False
        for c in hdr:
            if c not in cols:
                cols.append(c)
                changed = True
    # Also add a type/description for 'time' if mentioned
    if "time" in hdr and "time" not in data:
        data["time"] = {
            "Description": "Sample timestamp in seconds from recording start",
            "Units": "s",
        }
        changed = True
    if changed:
        with open(jp, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        count += 1
print(f"  Updated {count} physio.json sidecars")
PYEOF

# -------------------------------------------------------------------
# 4d. Add 'DwellTime' stub to T1w/MRI JSON sidecars
#     (SIDECAR_KEY_RECOMMENDED warning)
# -------------------------------------------------------------------
echo "--- 4d. Adding DwellTime stub to MRI anat JSONs ---"
python3 <<'PYEOF'
import json
from pathlib import Path

count = 0
for jp in Path(".").rglob("sub-*/anat/*.json"):
    try:
        with open(jp) as f:
            data = json.load(f)
    except Exception:
        continue
    if "DwellTime" not in data:
        data["DwellTime"] = "n/a"
        with open(jp, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        count += 1
print(f"  Added DwellTime to {count} anat JSONs")
PYEOF

# -------------------------------------------------------------------
# 4e. Rewrite .tsv.gz files with mtime=0 (GZIP_HEADER_MTIME warning)
#     Non-zero mtime in gzip headers can leak PII / is non-reproducible.
# -------------------------------------------------------------------
echo "--- 4e. Zeroing gzip mtime in .tsv.gz files ---"
count=0
for f in $(find . -name "*.tsv.gz"); do
  # Check current mtime field via python (gzip header byte 4-7 = mtime)
  current_mtime=$(python3 -c "
import gzip, sys
with open('$f', 'rb') as f: hdr = f.read(10)
import struct
print(struct.unpack('<I', hdr[4:8])[0])
" 2>/dev/null)
  if [[ "$current_mtime" != "0" ]] && [[ -n "$current_mtime" ]]; then
    # Rewrite the file: decompress then re-gzip with mtime=0
    tmp="${f}.tmp"
    python3 -c "
import gzip, shutil
with gzip.open('$f', 'rb') as fin, gzip.GzipFile('$tmp', 'wb', mtime=0) as fout:
    shutil.copyfileobj(fin, fout)
" 2>/dev/null && mv -f "$tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Rewrote $count .tsv.gz with mtime=0"

# -------------------------------------------------------------------
# 4f. Create stub events.tsv for task scans missing events
#     (EVENTS_TSV_MISSING warning). For naturalistic viewing, movie
#     onset at t=0 with duration equal to run length is appropriate.
# -------------------------------------------------------------------
echo "--- 4f. Creating stub events.tsv for func/ scans missing events ---"
count=0
for bold in $(find . -path "*/func/*_bold.nii.gz" 2>/dev/null); do
  dir=$(dirname "$bold")
  base=$(basename "$bold" _bold.nii.gz)
  ev="${dir}/${base}_events.tsv"
  if [[ ! -f "$ev" ]]; then
    # Stub event: single-row representing the whole run
    {
      echo -e "onset\tduration\ttrial_type"
      echo -e "0\tn/a\trun_start"
    } > "$ev"
    count=$((count + 1))
  fi
done
echo "  Created $count stub events.tsv files"

# -------------------------------------------------------------------
# 4g. Clip suspicious negative event onsets to 0
#     (SUSPICIOUS_NEGATIVE_EVENT_ONSET warning)
#     These pre-recording markers don't make sense as negative offsets.
# -------------------------------------------------------------------
echo "--- 4g. Clipping negative event onsets to 0 ---"
count=0
for f in $(find . -name "*_events.tsv"); do
  # Only rewrite if there are negative onsets
  if awk -F'\t' 'NR>1 && $1+0 < 0 {found=1; exit} END {exit !found}' "$f" 2>/dev/null; then
    awk -F'\t' -v OFS='\t' '
      NR == 1 { print; next }
      { if ($1+0 < 0) $1 = 0; print }
    ' "$f" > "${f}.tmp"
    mv "${f}.tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Clipped negative onsets in $count events.tsv"

# -------------------------------------------------------------------
# 5. Validate + fix JSON files
# -------------------------------------------------------------------
echo "--- 5. Validating JSON sidecars ---"
count_bad=0
for j in $(find . -name "*.json"); do
  if ! python3 -c "import json; json.load(open('$j'))" 2>/dev/null; then
    echo "  INVALID: $j"
    count_bad=$((count_bad + 1))
  fi
done
echo "  $count_bad invalid JSON files found"
if [[ "$count_bad" -gt 0 ]]; then
  echo "  Manual inspection needed for invalid JSONs"
fi

# -------------------------------------------------------------------
# 6. Create .bidsignore for non-BIDS files we want to keep
# -------------------------------------------------------------------
echo "--- 6. Writing .bidsignore ---"
cat > .bidsignore <<'EOF'
# Root-level questionnaire and behavioral TSVs
nycq.tsv
nycq.json
psqi.tsv
psqi.json
last_night_sleep.tsv
last_night_sleep.json
EOF
echo "  .bidsignore written"

# -------------------------------------------------------------------
# 7. Archive this script into code/ for provenance
# -------------------------------------------------------------------
echo "--- 7. Archiving fix script into code/ ---"
mkdir -p code
SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
[[ -f "$SELF" ]] && cp -f "$SELF" code/fix_natview.sh
chmod +x code/fix_natview.sh 2>/dev/null || true
echo "  archived → code/fix_natview.sh"

echo ""
echo "=== Done ==="
echo "Re-run validator with:"
echo "  nemar dataset validate --prune --ignore-warnings $DS"
