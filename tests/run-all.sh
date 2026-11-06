#!/usr/bin/env bash
#
# Run every test. No cluster needed.
#   bash tests/run-all.sh

cd "$(dirname "$0")/.." || exit 1
fail=0
for t in check-read-only test-guard test-redaction test-e2e-offline test-skill; do
  printf '== %s\n' "$t"
  if bash "tests/$t.sh"; then :; else fail=1; fi
  echo
done
[ "$fail" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
