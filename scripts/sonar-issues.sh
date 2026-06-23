#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sonar-issues.sh — list OPEN SonarQube/SonarCloud issues for THIS repo.
#
# Repo-agnostic: reads the project key and host from the repo's
# `sonar-project.properties`, so the same script drops into every project.
# Reads the state of the LAST analysis CI uploaded (push → CI → sonar-scanner),
# so the loop is: push → CI analyzes → run this → fix → repeat. Exits non-zero
# when anything is open, so it doubles as a pre-push gate.
#
# Auth:
#   * Public project  → no token needed.
#   * Private project → export SONAR_TOKEN=<user token>; the script sends it.
#
# Usage:
#   ./scripts/sonar-issues.sh                 # open issues on `main`
#   ./scripts/sonar-issues.sh <branch>        # open issues on a branch
#   ./scripts/sonar-issues.sh --pr <number>   # open issues on a pull request
#
# Requires: curl, python3.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
PROPS="$REPO_ROOT/sonar-project.properties"

if [[ ! -f "$PROPS" ]]; then
  echo "❌ Brak $PROPS — to repo nie jest skonfigurowane pod Sonara." >&2
  exit 2
fi

# Read a `key=value` from the properties file (key may contain dots).
prop() { grep -E "^${1//./\\.}=" "$PROPS" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

PROJECT="$(prop sonar.projectKey)"
HOST="$(prop sonar.host.url)"; HOST="${HOST:-https://sonarcloud.io}"
ORG="$(prop sonar.organization)"

if [[ -z "$PROJECT" ]]; then
  echo "❌ Nie znaleziono sonar.projectKey w $PROPS." >&2
  exit 2
fi

scope="branch=main"
if [[ "${1:-}" == "--pr" && -n "${2:-}" ]]; then
  scope="pullRequest=$2"
elif [[ -n "${1:-}" ]]; then
  scope="branch=$1"
fi

url="${HOST%/}/api/issues/search?componentKeys=${PROJECT}&${scope}&resolved=false&ps=500"
[[ -n "$ORG" ]] && url="${url}&organization=${ORG}"

# Token is optional (public projects need none). When set, SonarQube/SonarCloud
# takes it as the basic-auth username with an empty password.
auth=()
if [[ -n "${SONAR_TOKEN:-}" ]]; then auth=(-u "${SONAR_TOKEN}:"); fi

# Fetch to a temp file (not a pipe): the python program below is supplied on
# stdin via the heredoc, so the JSON must come from a file argument instead.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL ${auth[@]+"${auth[@]}"} "$url" -o "$tmp"; then
  echo "❌ Zapytanie do Sonara nie powiodło się. Prywatny projekt? Ustaw SONAR_TOKEN." >&2
  exit 2
fi

python3 - "$tmp" "$PROJECT" "$scope" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
project, scope = sys.argv[2], sys.argv[3]
issues = data.get("issues", [])
total = data.get("total", len(issues))
print(f"SonarCloud — {total} open issue(s)  [{project} · {scope}]\n")
sev_order = {"BLOCKER": 0, "CRITICAL": 1, "MAJOR": 2, "MINOR": 3, "INFO": 4}
for i in sorted(issues, key=lambda x: (sev_order.get(x.get("severity", "INFO"), 9),
                                       x.get("component", ""), x.get("line", 0))):
    path = i.get("component", "").split(":", 1)[-1]
    line = i.get("line", "?")
    print(f"  [{i.get('severity','?'):8}] {i.get('rule',''):16} {path}:{line}")
    print(f"             {i.get('message','').strip()}")
# Non-zero exit when anything is open, so it doubles as a pre-push gate.
sys.exit(1 if total else 0)
PY
