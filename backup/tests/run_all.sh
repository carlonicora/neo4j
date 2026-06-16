#!/bin/bash
# Run all backup shell tests. Exits non-zero if any suite fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in test_lib.sh test_backup_sh.sh test_retention_sh.sh test_restore_sh.sh; do
  echo "=== ${t} ==="
  bash "${HERE}/${t}" || rc=1
done
exit ${rc}
