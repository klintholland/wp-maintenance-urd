#!/bin/bash
set -euo pipefail
cd /www/urd_277/public

# Load environment-specific config, if it exists
if [ -f "maintenance/env-config.sh" ]; then
  echo "🔹 Loading config from maintenance/env-config.sh..."
  source "maintenance/env-config.sh"
fi

QWP="maintenance/wpq"
BUCKETS="maintenance/buckets"
STAMP="$(date +%F-%H%M%S)"
LOGDIR="/www/urd_277/public/maintenance/logs/$STAMP"
mkdir -p "$LOGDIR"

bash maintenance/categorize-plugins.sh

# --- DIAGNOSTIC: prove we have a bucket file and show candidates ---
echo "MED bucket path: $BUCKETS/medium.to_update"
ls -l "$BUCKETS/medium.to_update" || echo "(!) medium.to_update missing"
echo "MED candidates (first 20):"
head -n 20 "$BUCKETS/medium.to_update" || true
# ------------------------------------------------------------------

MED="$BUCKETS/medium.to_update"
if [ ! -s "$MED" ]; then
  echo "✅ Nothing to update in MEDIUM."
  exit 0
fi

echo "🔹 Pre-inventory" | tee "$LOGDIR/medium-pre.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/medium-pre.tsv"

LOGFILE="$LOGDIR/medium.log"
echo "🔹 Updating MEDIUM bucket (bulk)…" | tee -a "$LOGFILE"
xargs -a "$MED" -r $QWP plugin update | tee -a "$LOGFILE" || true

echo "🔹 Clear caches…" | tee -a "$LOGFILE"
$QWP transient delete --all >/dev/null 2>&1 || true
$QWP cache flush        >/dev/null 2>&1 || true

echo "🔹 Validate…" | tee -a "$LOGFILE"
bash maintenance/validate-site.sh || { echo "❌ MEDIUM validation failed"; }

echo "🔹 Post-inventory" | tee "$LOGDIR/medium-post.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/medium-post.tsv"

bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

echo ""
echo "────────────────────────────"
echo "📊 Generating update summary..."

# Get total from the "Success: Updated X of Y plugins." line
TOTAL_SUCCESS=$(grep -E "Success: Updated [0-9]+ of [0-9]+ plugins" "$LOGFILE" | sed -E 's/Success: Updated ([0-9]+) of .*/\1/' 2>/dev/null || echo 0)

# Get attempted from the same line "X of Y"
TOTAL_ATTEMPTED=$(grep -E "Success: Updated [0-9]+ of [0-9]+ plugins" "$LOGFILE" | sed -E 's/Success: Updated [0-9]+ of ([0-9]+) plugins.*/\1/' 2>/dev/null || echo 0)

# Skipped is still valid
TOTAL_SKIPPED=$(grep -ciE "already (up to date|updated|at the latest version)" "$LOGFILE" 2>/dev/null || echo 0)

echo "🧩  ${TOTAL_ATTEMPTED:-0} plugin updates attempted"
echo "✅  ${TOTAL_SUCCESS:-0} successfully updated"
echo "⏭️  ${TOTAL_SKIPPED:-0} already up-to-date"

FAILED_COUNT=$(( TOTAL_ATTEMPTED - TOTAL_SUCCESS ))
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "⚠️  $FAILED_COUNT failed"
fi

# --- List Successful ---
UPDATED_PLUGINS=$(grep -E "\s(Updated|Installed)$" "$LOGFILE" 2>/dev/null | awk '{print $1}' | sort -u)

if [ -n "$UPDATED_PLUGINS" ]; then
  echo "────────────────────────────"
  echo "✅  Updated Plugins:"
  echo "$UPDATED_PLUGINS" | sed 's/^/ - /'
elif [ "${TOTAL_SUCCESS:-0}" -eq 0 ]; then
  echo "ℹ️  No plugins were updated."
fi

# --- List Failures ---
FAILURE_LOG="$LOGDIR/failures.log"
# Check if the failures.log file exists and is not empty
if [ -s "$FAILURE_LOG" ]; then 
  echo "────────────────────────────"
  echo "❌  Failed Updates (from analyze-update-log.sh):"
  # Print the contents of the failure log, adding a bullet point to each line
  cat "$FAILURE_LOG" | sed 's/^/ - /'
fi

echo "────────────────────────────"
echo "🔎 Logs: $LOGDIR"
