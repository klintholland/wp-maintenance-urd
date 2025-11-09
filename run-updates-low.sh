#!/bin/bash
set -euo pipefail
cd /www/urd_277/public

QWP="maintenance/wpq"
BUCKETS="maintenance/buckets"
STAMP="$(date +%F-%H%M%S)"
LOGDIR="/www/urd_277/public/maintenance/logs/$STAMP"
mkdir -p "$LOGDIR"

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
BASE_URL="${BASE_URL:-https://env-urd-staging1109.kinsta.cloud}" \
PDP_URL="${PDP_URL:-https://env-urd-staging1109.kinsta.cloud/magnuson-supercharger-2005-2015-tacoma-v6/}" \
CART_URL="${CART_URL:-https://env-urd-staging1109.kinsta.cloud/cart/}" \
CHECKOUT_URL="${CHECKOUT_URL:-https://env-urd-staging1109.kinsta.cloud/checkout/}" \
ADMIN_PATH="${ADMIN_PATH:-/piads/}" \
FOOTER_TEXT="${FOOTER_TEXT:-Terms & Conditions}" \
bash maintenance/validate-site.sh || { echo "❌ LOW validation failed"; }

# --- Post-inventory
echo "🔹 Post-inventory" | tee "$LOGDIR/low-post.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/low-post.tsv"

# --- Analyze failures (hints)
bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

# --- Summary
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
