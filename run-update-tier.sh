#!/bin/bash
set -euo pipefail

if [ -z "$1" ]; then
  echo "❌ Error: Missing tier name. Usage: $0 [low|medium|high]"
  exit 1
fi

# 1. SET TIER-SPECIFIC VARIABLES
TIER_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]')
TIER_NAME_UPPER=$(echo "$1" | tr '[:lower:]' '[:upper:]')

# 2. STANDARD SETUP
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

echo "🚀 Starting $TIER_NAME_UPPER tier update process... (Logs: $LOGDIR)"

# Deactivate maintenance plugin to allow WP-CLI to run
echo "🔹 Deactivating 'urd-custom-maintenance' plugin..."
# Use standard deactivate, but if that fails (e.g. plugin HTML),
# try to force-move it as a fallback.
if ! $QWP plugin deactivate urd-custom-maintenance 2>/dev/null; then
    echo "🔹 Deactivate failed, trying force-move..."
    mv wp-content/plugins/urd-custom-maintenance wp-content/plugins/urd-custom-maintenance.DEACTIVATED >/dev/null 2>&1 || true
    $QWP cache flush >/dev/null 2>&1 || true
else
    echo "✅ 'urd-custom-maintenance' is deactivated."
fi


# Always rebuild buckets to get the latest list
bash maintenance/categorize-plugins.sh

BUCKET_FILE="$BUCKETS/$TIER_NAME.to_update"
if [ ! -s "$BUCKET_FILE" ]; then
  echo "✅ Nothing to update in $TIER_NAME_UPPER."
  exit 0
fi

# 3. PRE-INVENTORY
PRE_LOG="$LOGDIR/$TIER_NAME-pre.tsv"
echo "🔹 Pre-inventory" | tee "$PRE_LOG"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$PRE_LOG"

LOGFILE="$LOGDIR/$TIER_NAME.log"
echo "⚠️  Recommended: Create a Kinsta snapshot now (UI)." | tee -a "$LOGFILE"

# 4. ONE-BY-ONE UPDATE LOOP
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
done < "$BUCKET_FILE"

# 5. POST-INVENTORY
POST_LOG="$LOGDIR/$TIER_NAME-post.tsv"
echo "🔹 Post-inventory" | tee "$POST_LOG"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$POST_LOG"

bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

# 6. SUMMARY
echo ""
echo "────────────────────────────"
echo "📊 Generating update summary for $TIER_NAME_UPPER..."

# --- Calculate totals first ---
TOTAL_ATTEMPTED=$(grep -c "▶️  Updating" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SUCCESS=$(grep -cE "✅ .* OK after update" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SKIPPED=$(grep -ciE "already (up to date|updated|at the latest version)" "$LOGFILE" 2>/dev/null || echo 0)
FAILED_COUNT=$(( TOTAL_ATTEMPTED - TOTAL_SUCCESS ))

# --- Show totals ---
echo "🧩  ${TOTAL_ATTEMPTED:-0} plugin updates attempted"
echo "✅  ${TOTAL_SUCCESS:-0} successfully updated"
echo "⏭️  ${TOTAL_SKIPPED:-0} already up-to-date"
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "⚠️  $FAILED_COUNT failed or were rolled back"
fi

# --- List Attempted ---
echo "────────────────────────────"
echo "ℹ️  Plugins Attempted:"
cat "$BUCKET_FILE" | sed 's/^/ - /'

# --- List Successful ---
# This list is now built ONLY from the "✅ ... OK after update" log line,
# so it will directly match the TOTAL_SUCCESS count.
UPDATED_PLUGINS=$(
    grep -E "✅ .* OK after update\." "$LOGFILE" 2>/dev/null \
      | sed -E "s/^✅ ([^ ]+) OK after update\.$/\1/" \
      | sort -u
)

if [ -n "$UPDATED_PLUGINS" ]; then
  echo "────────────────────────────"
  echo "✅  Successfully Updated Plugins:"
  echo "$UPDATED_PLUGINS" | sed 's/^/ - /'
fi

# --- List Failures / Rollbacks ---
ROLLED_BACK_PLUGINS=$(grep "\[CULPRIT\]" "$LOGFILE" 2>/dev/null | sed -E 's/.*\[CULPRIT\] ([^ ]+).*/\1/' | sort -u)

if [ -n "$ROLLED_BACK_PLUGINS" ]; then
    echo "────────────────────────────"
    echo "❌  Rolled Back Plugins:"
    echo "$ROLLED_BACK_PLUGINS" | sed 's/^/ - /'
fi

# --- Show Failure Analysis Log (if any rollbacks) ---
FAILURE_LOG="$LOGDIR/failures.log"
if [ -n "$ROLLED_BACK_PLUGINS" ] && [ -s "$FAILURE_LOG" ]; then 
  echo "────────────────────────────"
  echo "ℹ️  Failure Analysis (from analyze-update-log.sh):"
  cat "$FAILURE_LOG" | sed 's/^/ - /'
fi

# --- Final "no updates" message ---
if [ "${TOTAL_SUCCESS:-0}" -eq 0 ] && [ -z "$ROLLED_BACK_PLUGINS" ]; then
     echo "ℹ️  No plugins were updated or rolled back."
fi

echo "────────────────────────────"
echo "🔎 Logs: $LOGDIR"
