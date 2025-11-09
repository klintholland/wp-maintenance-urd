#!/bin/bash
#
# Environment-specific config for the update scripts.
# This file should NOT be committed to Git.

#
# Environment-specific config for the update scripts.
# This file should NOT be committed to Git.

# ==========================================================
# ⬇️  ONLY EDIT THIS ONE VARIABLE WHEN YOU REBUILD ⬇️
# ==========================================================
export BASE_URL="https://stg-urd-staging.kinsta.cloud"

# ==========================================================
# Everything else is built automatically
# ==========================================================

# --- Site URLs
# These are built from BASE_URL. No need to edit.
export PDP_URL="${BASE_URL}/magnuson-supercharger-2005-2015-tacoma-v6/"
export CART_URL="${BASE_URL}/cart/"
export CHECKOUT_URL="${BASE_URL}/checkout/"

# --- Validation Settings
# These are standard for your site.
export ADMIN_PATH="/piads/"
export FOOTER_TEXT="Terms & Conditions"
