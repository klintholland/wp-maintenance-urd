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

# Deactivate maintenance plugin to allow WP-CLI to run
echo "🔹 Deactivating 'urd-custom-maintenance' plugin..."
$QWP plugin deactivate urd-custom-maintenance || true

# Build/update bucket lists
bash maintenance/categorize-plugins.sh

LOW="$BUCKETS/low.to_update"
if [ ! -s "$LOW" ]; then
  echo "✅ Nothing to update in LOW."
  exit 0
fi

echo "🔹 Pre-inventory" | tee "$LOGDIR/low-pre.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/low-pre.tsv"

# --- Updates
LOGFILE="$LOGDIR/low.log"
echo "🔹 Updating LOW bucket (bulk)…" | tee -a "$LOGFILE"
xargs -a "$LOW" -r $QWP plugin update | tee -a "$LOGFILE" || true

# --- Cache clear
echo "🔹 Clear caches…" | tee -a "$LOGFILE"
$QWP transient delete --all >/dev/null 2>&1 || true
$QWP cache flush        >/dev/null 2>&1 || true

# --- Validation (staging defaults; override with env vars when needed)
echo "🔹 Validate…" | tee -a "$LOGFILE"
LOGDIR="$LOGDIR" bash maintenance/validate-site.sh || { echo "❌ LOW validation failed"; }

# --- Post-inventory
echo "🔹 Post-inventory" | tee "$LOGDIR/low-post.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/low-post.tsv"

# --- Analyze failures (hints)
bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

# --- Summary
echo ""
echo "────────────────────────────"
echo "📊 Generating update summary..."

# NEW: Count plugins from the results table
TOTAL_ATTEMPTED=$(grep -cE "\s(Updated|Installed|Error)$" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SUCCESS=$(grep -cE "\s(Updated|Installed)$" "$LOGFILE" 2>/dev/null || echo 0)
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
