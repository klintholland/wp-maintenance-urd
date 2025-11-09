#!/bin/bash
# Creates three lists of slugs to consider for updates, intersecting manifest with live plugins.
set -euo pipefail
cd /www/urd_277/public

MANIFEST="maintenance/plugin-risk-manifest.json"
QWP="maintenance/wpq"
OUTDIR="maintenance/buckets"
mkdir -p "$OUTDIR"

if [ ! -f "$MANIFEST" ]; then echo "Missing $MANIFEST"; exit 1; fi

# Live plugin slugs
$QWP plugin list --field=name > maintenance/_live_plugins.txt

jq -r '.high[]' "$MANIFEST" | sort -u > "$OUTDIR/high.manifest"
jq -r '.medium[]' "$MANIFEST" | sort -u > "$OUTDIR/medium.manifest"
jq -r '.low[]' "$MANIFEST" | sort -u > "$OUTDIR/low.manifest"

for tier in high medium low; do
  # Intersect manifest with live. Add || true so 'grep' doesn't fail on "no matches".
  grep -Fxf "$OUTDIR/$tier.manifest" maintenance/_live_plugins.txt | sort -u > "$OUTDIR/$tier.live" || true
done

echo "Buckets ready in $OUTDIR:"
ls -1 "$OUTDIR"/*.to_update || true

# Only ACTIVE updates for medium/high; ALL updates (incl. inactive) for low
$QWP plugin list --status=active --update=available --field=name > "$OUTDIR/_active_updates.txt" || true
$QWP plugin list --update=available --field=name > "$OUTDIR/_all_updates.txt" || true

# Build .to_update per tier (low uses ALL updates; medium/high use ACTIVE updates)
grep -Fxf "$OUTDIR/high.live"   "$OUTDIR/_active_updates.txt" | sort -u > "$OUTDIR/high.to_update"   || true
grep -Fxf "$OUTDIR/medium.live" "$OUTDIR/_active_updates.txt" | sort -u > "$OUTDIR/medium.to_update" || true
grep -Fxf "$OUTDIR/low.live"    "$OUTDIR/_all_updates.txt"    | sort -u > "$OUTDIR/low.to_update"    || true

echo "   • high:   $(wc -l < "$OUTDIR/high.to_update"   2>/dev/null || echo 0) to update (active only)"
echo "   • medium: $(wc -l < "$OUTDIR/medium.to_update" 2>/dev/null || echo 0) to update (active only)"
echo "   • low:    $(wc -l < "$OUTDIR/low.to_update"    2>/dev/null || echo 0) to update (active + inactive)"
