#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: restore.sh"
bash -n "${HERE}/../restore.sh"; assert_success $? "restore.sh parses"

finish
