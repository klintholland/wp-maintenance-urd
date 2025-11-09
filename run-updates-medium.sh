#!/bin/bash
set -euo pipefail
cd /www/urd_277/public

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
BASE_URL="${BASE_URL:-https://env-urd-staging1109.kinsta.cloud}" \
PDP_URL="${PDP_URL:-https://env-urd-staging1109.kinsta.cloud/magnuson-supercharger-2005-2015-tacoma-v6/}" \
CART_URL="${CART_URL:-https://env-urd-staging1109.kinsta.cloud/cart/}" \
CHECKOUT_URL="${CHECKOUT_URL:-https://env-urd-staging1109.kinsta.cloud/checkout/}" \
ADMIN_PATH="${ADMIN_PATH:-/piads/}" \
FOOTER_TEXT="${FOOTER_TEXT:-Terms & Conditions}" \
bash maintenance/validate-site.sh || { echo "❌ MEDIUM validation failed"; }

echo "🔹 Post-inventory" | tee "$LOGDIR/medium-post.tsv"
$QWP plugin list --fields=name,status,version,update_version | tee -a "$LOGDIR/medium-post.tsv"

bash maintenance/analyze-update-log.sh "$LOGFILE" > "$LOGDIR/failures.log" || true

echo ""
echo "────────────────────────────"
echo "📊 Generating update summary..."

TOTAL_ATTEMPTED=$(grep -cE "Updating|Installing the latest version" "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SUCCESS=$(grep -cE "Success: (Updated|Installed)"            "$LOGFILE" 2>/dev/null || echo 0)
TOTAL_SKIPPED=$(grep -ciE "already (up to date|updated|at the latest version)" "$LOGFILE" 2>/dev/null || echo 0)

echo "🧩  ${TOTAL_ATTEMPTED:-0} plugin updates attempted"
echo "✅  ${TOTAL_SUCCESS:-0} successfully updated"
echo "⏭️  ${TOTAL_SKIPPED:-0} already up-to-date"
if [ "${TOTAL_ATTEMPTED:-0}" -gt "${TOTAL_SUCCESS:-0}" ]; then
  echo "⚠️  $(( TOTAL_ATTEMPTED - TOTAL_SUCCESS )) failed (see $LOGDIR/failures.log)"
fi

UPDATED_PLUGINS=$(grep -E "Success: (Updated|Installed)" "$LOGFILE" 2>/dev/null \
  | sed -E "s/.*‘([^’]+)’\..*/\1/" | sort -u)

if [ -n "$UPDATED_PLUGINS" ]; then
  echo "────────────────────────────"
  echo "✅  Updated:"
  echo "$UPDATED_PLUGINS" | sed 's/^/ - /'
else
  echo "ℹ️  No plugins updated."
fi

echo "────────────────────────────"
echo "🔎 Logs: $LOGDIR"
