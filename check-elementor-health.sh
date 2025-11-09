#!/bin/bash
# ============================================
# URDUSA - Elementor Health Check
# Checks memory limit, version pairing, cache size, and admin impact
# ============================================

set -e
cd /www/urd_277/public

QWP="/www/urd_277/public/maintenance/wpq"
echo "🔍 Elementor Health Check - $(date)"

# ------------------------------------------------------------
# 1️⃣ PHP Memory
# ------------------------------------------------------------
MEM=$($QWP eval 'echo ini_get("memory_limit");' | tr -d '\r')
if [[ "$MEM" == "-1" ]]; then
  echo "✅ PHP memory_limit: Unlimited (-1)"
elif [[ "${MEM/M/}" != "$MEM" && "${MEM/M/}" -ge 512 ]]; then
  echo "✅ PHP memory_limit: $MEM (OK)"
else
  echo "⚠️  PHP memory_limit is $MEM (recommended ≥512M or -1)"
fi

# ------------------------------------------------------------
# 2️⃣ Elementor Versions
# ------------------------------------------------------------
CORE_VER=$($QWP plugin get elementor --fields=version --format=ids 2>/dev/null || echo "n/a")
PRO_VER=$($QWP plugin get elementor-pro --fields=version --format=ids 2>/dev/null || echo "n/a")

echo "🔹 Elementor core: $CORE_VER"
echo "🔹 Elementor Pro:  $PRO_VER"

if [[ "$CORE_VER" == "n/a" || "$PRO_VER" == "n/a" ]]; then
  echo "❌ Elementor or Elementor Pro is inactive or missing."
else
  CORE_MAJOR=$(echo "$CORE_VER" | cut -d'.' -f1-2)
  PRO_MAJOR=$(echo "$PRO_VER" | cut -d'.' -f1-2)
  if [[ "$CORE_MAJOR" == "$PRO_MAJOR" ]]; then
    echo "✅ Version pairing OK ($CORE_MAJOR.x)"
  else
    echo "❌ Version mismatch: core=$CORE_VER, pro=$PRO_VER"
    echo "   → Visit https://elementor.com/help/elementor-pro-version-compatibility/ for matching pair."
  fi
fi

# ------------------------------------------------------------
# 3️⃣ Elementor cache footprint
# ------------------------------------------------------------
CSS_DIR="wp-content/uploads/elementor/css"
if [ -d "$CSS_DIR" ]; then
  SIZE=$(du -sh "$CSS_DIR" 2>/dev/null | awk '{print $1}')
  echo "🔹 Elementor CSS cache: $SIZE in $CSS_DIR"
  [ "$(du -s "$CSS_DIR" | awk '{print $1}')" -gt 100000 ] && echo "⚠️  Consider clearing Elementor cache (Tools → Regenerate CSS & Data)."
else
  echo "ℹ️  No Elementor CSS cache directory yet."
fi

# ------------------------------------------------------------
# 4️⃣ Woo Admin load status
# ------------------------------------------------------------
if [ -f "wp-content/mu-plugins/disable-woo-admin.php" ]; then
  echo "✅ Woo Admin temporarily disabled (recommended while testing Elementor)."
else
  echo "ℹ️  Woo Admin active; monitor admin memory usage."
fi

# ------------------------------------------------------------
# 5️⃣ Admin accessibility test
# ------------------------------------------------------------
echo "🔹 Checking /wp-admin reachability..."
curl -s -o /dev/null -w "   HTTP %{http_code}\n" https://stg-urd-staging.kinsta.cloud/wp-admin/ || echo "⚠️  Curl check failed (verify URL/path)."

echo "✅ Elementor Health Check complete."
