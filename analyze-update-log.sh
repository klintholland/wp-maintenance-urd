#!/bin/bash
# Usage: ./analyze-update-log.sh /path/to/log > /path/to/failures.log
set -euo pipefail
LOG="${1:-/dev/stdin}"

grep -E "Error|failed|Failure|forbidden|denied|unauthorized|not available|could not|incompatible|checksum|license|update package" -i "$LOG" \
| sed -E '
  s#.*advanced-custom-fields-pro.*Error.*#ACF Pro update error → likely license inactive or no update package available.#I;
  s#.*update package not available.*#Update package not available → typically license/subscription issue.#I;
  s#.*unauthorized|forbidden|403.*#HTTP 401/403 from vendor → license or auth blocked.#I;
  s#.*could not create directory|permission denied.*#Filesystem permissions or disk quota issue.#I;
  s#.*Incompatible Archive.*#Bad/corrupted ZIP from vendor.#I;
  s#.*checksum.*#Checksum mismatch → incomplete download or CDN issue.#I;
' \
| awk '!seen[$0]++'
