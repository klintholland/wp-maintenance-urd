#!/bin/bash
set -euo pipefail
cd /www/urd_277/public

echo "▶️  LOW bucket..."
bash maintenance/run-updates-low.sh

echo "▶️  MEDIUM bucket..."
bash maintenance/run-updates-medium.sh

echo "▶️  HIGH bucket (one-by-one, with rollback)..."
bash maintenance/run-updates-high.sh

echo "✅ All buckets processed."
