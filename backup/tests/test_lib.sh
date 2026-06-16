#!/bin/bash
# Runnable test suite for backup/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"
source "${HERE}/../lib.sh"

echo "test: s3_configured"
S3_BUCKET="" S3_ENDPOINT="" ; if s3_configured; then assert_failure 0 "unset => not configured"; else assert_success 0 "unset => not configured"; fi
S3_BUCKET="b" S3_ENDPOINT="https://e" ; if s3_configured; then assert_success 0 "both set => configured"; else assert_failure 0 "both set => configured"; fi
S3_BUCKET="b" S3_ENDPOINT="" ; if s3_configured; then assert_failure 0 "endpoint missing => not configured"; else assert_success 0 "endpoint missing => not configured"; fi
S3_BUCKET="" S3_ENDPOINT="https://e" ; if s3_configured; then assert_failure 0 "bucket missing => not configured"; else assert_success 0 "bucket missing => not configured"; fi

echo "test: NEO4J_ADMIN_IMAGE default"
assert_eq "neo4j/neo4j-admin:5.26-community-bullseye" \
  "$(unset NEO4J_ADMIN_IMAGE; source "${HERE}/../lib.sh"; echo "${NEO4J_ADMIN_IMAGE}")" \
  "image default set"

echo "test: estimate_dump_size"
setup_stub_path
make_stub du 'echo "100	$2"'
DATA_DIR="/data"
assert_eq "102400" "$(estimate_dump_size neo4j)" "100KB => 102400 bytes"
teardown_stub_path

finish
