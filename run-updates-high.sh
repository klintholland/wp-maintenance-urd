#!/bin/bash
set -euo pipefail
cd /www/urd_277/public
bash maintenance/run-update-tier.sh "high"
