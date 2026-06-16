#!/bin/bash
# Test helpers for backup/lib.sh. Bash 3.2 compatible (no associative arrays/mapfile).
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

setup_stub_path() {
  STUB_BIN=$(mktemp -d "${TMPDIR:-/tmp}/stubbin.XXXXXX")
  ORIG_PATH="$PATH"
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

teardown_stub_path() {
  PATH="${ORIG_PATH:?setup_stub_path not called}"
  rm -rf "${STUB_BIN:?}"
  unset STUB_BIN ORIG_PATH
}

# make_stub <name> <body-of-script>
make_stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "${body}" > "${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" = "$2" ]; then echo "  ok: $3";
  else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $3 (expected '$1', got '$2')"; fi
}
assert_success() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" -eq 0 ]; then echo "  ok: $2"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $2 (rc=$1)"; fi
}
assert_failure() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" -ne 0 ]; then echo "  ok: $2"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $2 (expected failure, got rc 0)"; fi
}
finish() {
  echo "----"; echo "Ran ${TESTS_RUN}, failed ${TESTS_FAILED}"
  [ "${TESTS_FAILED}" -eq 0 ]
}
