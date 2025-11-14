#!/bin/bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://env-urd-staging1109.kinsta.cloud}"
PDP_URL="${PDP_URL:-https://env-urd-staging1109.kinsta.cloud/magnuson-supercharger-2005-2015-tacoma-v6/}"
CART_URL="${CART_URL:-https://env-urd-staging1109.kinsta.cloud/cart/}"
CHECKOUT_URL="${CHECKOUT_URL:-https://env-urd-staging1109.kinsta.cloud/checkout/}"
FOOTER_TEXT="${FOOTER_TEXT:-Terms & Conditions}"
ADMIN_PATH="${ADMIN_PATH:-/piads/}"

QWP="/www/urd_277/public/maintenance/wpq"
STAMP="$(date +%F-%H%M%S)"

if [ -z "${LOGDIR:-}" ]; then
  OUTDIR="/www/urd_277/public/maintenance/logs/$STAMP"
else
  OUTDIR="$LOGDIR"
fi
mkdir -p "$OUTDIR"

curl_check () {
  local url="$1"; local expect="$2"; local name="$3"
  # Check for both the short and long error text
  local critical_error_text_1="critical error"
  local critical_error_text_2="There has been a critical error on this website" 

  # Add cache-busting headers to curl to get the "real" page
  code=$(curl -sS -L \
    -H "Cache-Control: no-cache, no-store, must-revalidate" \
    -H "Pragma: no-cache" \
    -H "Expires: 0" \
    -o /tmp/resp.html -w "%{http_code}" "$url" || true)

  if [ "$code" != "200" ] && [ "$code" != "302" ]; then
    echo "❌ $name HTTP $code for $url" | tee -a "$OUTDIR/validate.txt"; return 1
  fi
  
  # --- Re-ordered checks. Fail-fast. ---

  # Check 1: Fail if we see the general critical error text
  if grep -qi "$critical_error_text_1" /tmp/resp.html 2>/dev/null; then
    echo "❌ $name FAILED. Found text: '$critical_error_text_1'" | tee -a "$OUTDIR/validate.txt"; return 1
  fi
  
  # Check 2: Fail if we see the FULL critical error text
  if grep -qi "$critical_error_text_2" /tmp/resp.html 2>/dev/null; then
    echo "❌ $name FAILED. Found text: 'There has been a critical error...'" | tee -a "$OUTDIR/validate.txt"; return 1
  fi

  # Check 3: This is the main success check. If this fails, the page is broken or incomplete.
  if ! grep -qi "$expect" /tmp/resp.html 2>/dev/null; then
    echo "❌ $name missing expected text: $expect" | tee -a "$OUTDIR/validate.txt"; return 1
  fi

  # If all checks passed, the page is OK
  echo "✅ $name OK ($code)" | tee -a "$OUTDIR/validate.txt"; return 0
}

echo "🔎 Validation @ $STAMP" | tee "$OUTDIR/validate.txt"
curl_check "$BASE_URL" "$FOOTER_TEXT" "Home"   || VAL_FAIL=1
curl_check "$PDP_URL"  "$FOOTER_TEXT" "PDP"    || VAL_FAIL=1
curl_check "$CART_URL" "$FOOTER_TEXT" "Cart"   || VAL_FAIL=1
curl_check "$CHECKOUT_URL" "$FOOTER_TEXT" "Checkout" || VAL_FAIL=1

# Admin reachability
ADMIN_URL="${BASE_URL%/}${ADMIN_PATH}"
ADM_CODE=$(curl -sS -L -o /dev/null -w "%{http_code}" "$ADMIN_URL" || true)
if [[ "$ADM_CODE" =~ ^(200|302|403)$ ]]; then
  echo "✅ admin reachable/secured ($ADM_CODE) @ $ADMIN_URL" | tee -a "$OUTDIR/validate.txt"
else
  echo "❌ admin unreachable ($ADM_CODE) @ $ADMIN_URL" | tee -a "$OUTDIR/validate.txt"; VAL_FAIL=1
fi

# Woo maintenance
$QWP wc update >/dev/null 2>&1 || true
$QWP wc tool run regenerate_product_lookup_tables --user=1 >/dev/null 2>&1 || true

# Logs snapshot
LOGDIR_WOO="/www/urd_277/public/wp-content/uploads/wc-logs"
if [ -d "$LOGDIR_WOO" ]; then
  echo "🔹 Last 50 lines of Woo logs:" | tee -a "$OUTDIR/validate.txt"
  tail -n 50 "$LOGDIR_WOO"/* 2>/dev/null | tee -a "$OUTDIR/validate.txt" || true
else
  echo "ℹ️ No Woo logs dir yet." | tee -a "$OUTDIR/validate.txt"
fi

# Elementor pair enforcement
CORE_VER=$($QWP plugin get elementor --fields=version --format=ids 2>/dev/null || echo "")
PRO_VER=$($QWP plugin get elementor-pro --fields=version --format=ids 2>/dev/null || echo "")
if [ -n "$CORE_VER" ] && [ -n "$PRO_VER" ]; then
  CORE_MM=$(echo "$CORE_VER" | cut -d'.' -f1-2)
  PRO_MM=$(echo "$PRO_VER"  | cut -d'.' -f1-2)
  if [ "$CORE_MM" != "$PRO_MM" ]; then
    echo "❌ Elementor mismatch core=$CORE_VER pro=$PRO_VER → enforcing pair…" | tee -a "$OUTDIR/validate.txt"
    if $QWP plugin install elementor --version="$PRO_VER" --force >/dev/null 2>&1; then
      echo "✅ Elementor core pinned to $PRO_VER to match Pro." | tee -a "$OUTDIR/validate.txt"
    else
      echo "❌ Failed to pin Elementor core to $PRO_VER. Manual Pro ZIP install likely needed." | tee -a "$OUTDIR/validate.txt"
      VAL_FAIL=1
    fi
  else
    echo "✅ Elementor pair OK ($CORE_VER / $PRO_VER)" | tee -a "$OUTDIR/validate.txt"
  fi
fi

if [ "${VAL_FAIL:-0}" = "1" ]; then
  echo "❌ VALIDATION FAILED (see $OUTDIR/validate.txt)"; exit 1
else
  echo "✅ VALIDATION PASSED (see $OUTDIR/validate.txt)"; exit 0
fi
