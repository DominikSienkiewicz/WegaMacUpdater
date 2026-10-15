#!/usr/bin/env bash
set -euo pipefail

# Zestawy testów z twardym limitem czasu rzeczywistego na prawdziwych procesach albo na
# runtime'ie asynchronicznym. Uruchamiane równolegle z resztą przekraczały limit
# (29.09, 05.10 i 14.10.2026), więc build.yml i check.sh puszczają je osobno i szeregowo.
# Jedno źródło listy; kompletność pilnuje scripts/test-timing-suites-guard.sh.
#
# Wypisuje wyrażenie regularne dla `swift test --filter` i `--skip`.

SUITES=(
    BoundedProcessTests
    LT02LaunchSmokeProcessLifetimeTests
    LT02LaunchSmokeTestTests
    PrivilegedHelperDeadlineTests
    ProcessRunnerStarvationTests
)

(IFS='|'; printf '\\.(%s)/\n' "${SUITES[*]}")
