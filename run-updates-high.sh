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

bash maintenance/categorize-plugins.sh

HIGH="$BUCKETS/high.to_update"
if [ ! -s "$HIGH" ]; then
  echo "✅ Nothing to update in HIGH."
  exit 0
fi

echo "🔹 Pre-inventory" | tee "$LOGDIR/high-pre.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/high-pre.tsv"

LOGFILE="$LOGDIR/high.log"
echo "⚠️  Recommended: Create a Kinsta snapshot now (UI)." | tee -a "$LOGFILE"

while read -r SLUG; do
  [ -z "$SLUG" ] && continue
  CUR_VER="$($QWP plugin get "$SLUG" --field=version 2>/dev/null || echo "")"
  if [ -z "$CUR_VER" ]; then
    echo "ℹ️  $SLUG not found, skipping." | tee -a "$LOGFILE"
    continue
  fi

  echo "▶️  Updating $SLUG (was $CUR_VER)..." | tee -a "$LOGFILE"
  if ! $QWP plugin update "$SLUG" | tee -a "$LOGFILE"; then
    echo "❌ Update failed for $SLUG → rolling back to $CUR_VER" | tee -a "$LOGFILE"
    $QWP plugin install "$SLUG" --version="$CUR_VER" --force | tee -a "$LOGFILE" || echo "❌ Rollback command failed for $SLUG" | tee -a "$LOGFILE"
    echo "[CULPRIT] $SLUG update command failed; rolled back." | tee -a "$LOGFILE"
    continue
  fi

  echo "🔹 Clear caches…" | tee -a "$LOGFILE"
  $QWP transient delete --all >/dev/null 2>&1 || true
  $QWP cache flush        >/dev/null 2>&1 || true

  echo "🔹 Validate after $SLUG…" | tee -a "$LOGFILE"
  if ! LOGDIR="$LOGDIR" bash maintenance/validate-site.sh; then
    echo "❌ Validation failed after $SLUG → rolling back to $CUR_VER" | tee -a "$LOGFILE"
    if $QWP plugin install "$SLUG" --version="$CUR_VER" --force | tee -a "$LOGFILE"; then
      echo "✅ Rolled back $SLUG to $CUR_VER" | tee -a "$LOGFILE"
    else
      echo "❌ Rollback failed for $SLUG. Use Kinsta snapshot." | tee -a "$LOGFILE"
    fi
    echo "[CULPRIT] $SLUG failed validation; rolled back." | tee -a "$LOGFILE"
  else
    echo "✅ $SLUG OK after update." | tee -a "$LOGFILE"
  fi
done < "$HIGH"

echo "🔹 Post-inventory" | tee "$LOGDIR/high-post.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/high-post.tsv"

bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

echo ""
echo "────────────────────────────"
echo "📊 Generating update summary..."

TOTAL_ATTEMPTED=$(grep -cE "Updating|Installing the latest version" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SUCCESS=$(grep -cE "Success: (Updated|Installed)|✅ .* OK after update" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SKIPPED=$(grep -ciE "already (up to date|updated|at the latest version)" "$LOGFILE" 2>/dev/null || echo 0)

echo "🧩  ${TOTAL_ATTEMPTED:-0} plugin updates attempted"
echo "✅  ${TOTAL_SUCCESS:-0} successfully updated"
echo "⏭️  ${TOTAL_SKIPPED:-0} already up-to-date"

FAILED_COUNT=$(( TOTAL_ATTEMPTED - TOTAL_SUCCESS ))
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "⚠️  $FAILED_COUNT failed or were rolled back"
fi

# --- List Failures / Rollbacks ---
# We find rollbacks by looking for our [CULPRIT] tag in the log
ROLLED_BACK_PLUGINS=$(grep "\[CULPRIT\]" "$LOGFILE" 2>/dev/null | sed -E 's/.*\[CULPRIT\] ([^ ]+).*/\1/' | sort -u)

if [ -n "$ROLLED_BACK_PLUGINS" ]; then
    echo "────────────────────────────"
    echo "❌  Rolled Back Plugins:"
    echo "$ROLLED_BACK_PLUGINS" | sed 's/^/ - /'
fi

# --- List Successful ---
# This logic is specific to the 'high' script and is correct
UPDATED_PLUGINS=$(
  { grep -E "Success: (Updated|Installed)" "$LOGFILE" 2>/dev/null \
      | sed -E "s/.*‘([^’]+)’\..*/\1/"; \
    grep -E "✅ .* OK after update\." "$LOGFILE" 2>/dev/null \
      | sed -E "s/^✅ ([^ ]+) OK after update\.$/\1/"; } \
  | sort -u
)

if [ -n "$UPDATED_PLUGINS" ]; then
  echo "────────────────────────────"
  echo "✅  Updated Plugins:"
  echo "$UPDATED_PLUGINS" | sed 's/^/ - /'
else
  echo "ℹ️  No plugins updated."
fi

# --- Show Failure Analysis Log ---
# This is still useful for any non-rollback failures
FAILURE_LOG="$LOGDIR/failures.log"
if [ -s "$FAILURE_LOG" ]; then 
  echo "────────────────────────────"
  echo "ℹ️  Failure Analysis (from analyze-update-log.sh):"
  cat "$FAILURE_LOG" | sed 's/^/ - /'
fi

echo "────────────────────────────"
echo "🔎 Logs: $LOGDIR"
