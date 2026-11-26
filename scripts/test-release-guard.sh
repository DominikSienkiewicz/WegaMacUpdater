#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-release-guard.sh — test regresyjny jednofazowego `release.sh`.
#
# Notatki wydania stają się opisem GitHub Release bez żadnej dalszej obróbki, więc
# skrypt ma je przepisać bajt w bajt (poza obciętymi pustymi liniami na brzegach),
# odmówić tego, czego przepisać nie może, i atomowo wysłać commit oraz tag.
#
# `--publication-unit` uruchamia tylko testy publikacji z podstawioną warstwą Git remote.
# `--reviewed-notes-unit` sprawdza przygotowanie i zatwierdzenie opisu z atrapą Claude Code.
# `--release-body-unit` sprawdza treść przekazaną przez workflow do atrapy gh.
# Przypadki 1–16 sprawdzają zachowanie prawdziwego skryptu na jednorazowych repozytoriach.
# Przypadek 17 czyta skill wydania (.claude/skills/release/SKILL.md) z drzewa repozytorium
# i pilnuje, żeby wywoływał skrypt i push dokładnie w formie, którą przyjmują release.sh
# i hook git-guard.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RELEASE_SH="$ROOT/scripts/release.sh"
VERSION_FILE="Sources/WegaHelperKit/AppMetadata.swift"
failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    failures=$((failures + 1))
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/release-guard-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Repozytorium z wersją 0.1.0 i CHANGELOG-iem zawierającym tylko [Unreleased].
# Trzeci argument (dowolny) dodaje bare origin w piaskownicy i wypycha do niego main.
make_repo() {
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/Sources/WegaHelperKit"

    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config user.email guard@example.invalid
    git -C "$repo" config user.name  "Release Guard"
    git -C "$repo" config core.hooksPath /dev/null

    cat > "$repo/$VERSION_FILE" <<'SWIFT'
public enum AppMetadata {
    public static let displayName = "Wega Mac Updater"
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.wega.WegaMacUpdater"
}
SWIFT

    {
        printf '# Changelog\n\n## [Unreleased]\n\n'
        printf '%s\n' "${2-}"
    } > "$repo/CHANGELOG.md"

    git -C "$repo" add -A
    git -C "$repo" commit -q -m "feat: seed the fixture"

    if [ -n "${3-}" ]; then
        git -c init.defaultBranch=main init -q --bare "$SANDBOX/$1.git"
        git -C "$repo" remote add origin "$SANDBOX/$1.git"
        git -C "$repo" push -q origin main
    fi
    printf '%s' "$repo"
}

# Zastępuje CHANGELOG.md i commituje, żeby drzewo zostało czyste.
set_changelog() {
    printf '%s' "$2" > "$1/CHANGELOG.md"
    git -C "$1" add -A
    git -C "$1" commit -q -m "docs: changelog fixture"
}

# Uruchamia release.sh w podanym katalogu; wynik w OUT (stdout+stderr) i RC.
run_release() {
    local dir="$1"; shift
    OUT="$(cd "$dir" && PATH="$SANDBOX/claude-bin:$PATH" "$RELEASE_SH" "$@" 2>&1)"
    RC=$?
}

run_local_release() {
    WEGA_RELEASE_LOCAL_ONLY=1 run_release "$@"
}

# Obcina puste linie z brzegów; resztę zostawia bez zmian.
trim_blanks() {
    awk '
        /^[[:space:]]*$/ { if (started) held[++n] = $0; next }
        { for (i = 1; i <= n; i++) print held[i]; n = 0; started = 1; print }
    ' "$1"
}

# Treść sekcji wersji ($2) z CHANGELOG.md repozytorium $1, bez pustych linii na brzegach.
section() {
    awk -v h="## [$2]" '
        index($0, h) == 1 { inside = 1; next }
        inside && /^## \[/ { exit }
        inside { print }
    ' "$1/CHANGELOG.md" > "$SANDBOX/section.tmp"
    trim_blanks "$SANDBOX/section.tmp"
}

unreleased_body() {
    awk '
        /^## \[Unreleased\]/ { inside = 1; next }
        inside && /^## \[/ { exit }
        inside { print }
    ' "$1/CHANGELOG.md" | tr -d '[:space:]'
}

version_of() {
    (cd "$1" && sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$VERSION_FILE" | head -1)
}

head_of() { git -C "$1" rev-parse HEAD; }
tags_of() { git -C "$1" tag --list | paste -sd, -; }
dirty_of() { git -C "$1" status --porcelain; }

# Stan, który po odmowie ma pozostać nietknięty.
snapshot() { printf '%s|%s|%s' "$(head_of "$1")" "$(tags_of "$1")" "$(dirty_of "$1")"; }

write_notes() { printf '%s\n' "$2" > "$1"; }

stub_remote_git() {
    local git_bin="$SANDBOX/bin"
    mkdir -p "$git_bin"
    cat > "$git_bin/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
    remote) printf '%s\n' 'https://example.invalid/o/r.git' ;;
    fetch) exit "${RELEASE_TEST_FETCH_STATUS:-0}" ;;
    ls-remote)
        if [ "${!#}" = 'refs/tags/v*' ] && [ -n "${RELEASE_TEST_REMOTE_TAGS-}" ]; then
            cat "$RELEASE_TEST_REMOTE_TAGS"
        fi
        ;;
    push)
        printf '%s\n' "$@" > "$RELEASE_TEST_PUSH_ARGS"
        exit "${RELEASE_TEST_PUSH_STATUS:-0}"
        ;;
    *) exec "$RELEASE_TEST_GIT" "$@" ;;
esac
GIT
    chmod +x "$git_bin/git"
    RELEASE_TEST_GIT="$(command -v git)"
    export RELEASE_TEST_GIT
}

check_reviewed_notes() {
    local repo old base notes
    local RELEASE_TEST_PUSH_ARGS="$SANDBOX/review-push" RELEASE_TEST_REMOTE_TAGS="$SANDBOX/tags"
    local RELEASE_TEST_INPUT="$SANDBOX/model-input" RELEASE_TEST_NOTES="$SANDBOX/expected-notes"
    export RELEASE_TEST_PUSH_ARGS RELEASE_TEST_REMOTE_TAGS RELEASE_TEST_INPUT RELEASE_TEST_NOTES
    repo="$(make_repo reviewed-notes '')"
    set_changelog "$repo" $'# Changelog\n\n## [Unreleased]\n\n### Added\n- Curated draft\n\n## [0.1.0] — 2026-01-01\n\n- Earlier release\n'
    base="$(head_of "$repo")"
    git -C "$repo" commit --allow-empty -qm 'feat: add a preview' -m 'Select pending items in Settings.'
    git -C "$repo" commit --allow-empty -qm 'fix: retain selection' -m 'Keep choices across refreshes.'
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    printf '%s\trefs/tags/v0.1.0\n' "$base" > "$RELEASE_TEST_REMOTE_TAGS"
    printf '%s\n' '### Added' '- **Preview pending items** in Settings.' '' '### Fixed' '- Keep choices across refreshes.' > "$RELEASE_TEST_NOTES"
    notes="$(cat "$RELEASE_TEST_NOTES")"
    old="$(snapshot "$repo")"
    PATH="$SANDBOX/bin:$PATH" WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" <<< N
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *'feat: add a preview'*"$notes"*'Publish v0.1.1?'*'release cancelled'* ]] \
       && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$RELEASE_TEST_PUSH_ARGS" ] \
       && [ -f "$RELEASE_TEST_INPUT" ] && grep -Fq 'Select pending items in Settings.' "$RELEASE_TEST_INPUT" \
       && grep -Fq 'Keep choices across refreshes.' "$RELEASE_TEST_INPUT" \
       && grep -Fq 'feat: add a preview' "$RELEASE_TEST_INPUT" && grep -Fq 'fix: retain selection' "$RELEASE_TEST_INPUT" \
       && ! grep -Eq 'seed the fixture|changelog fixture|Earlier release' "$RELEASE_TEST_INPUT"; then
        record_pass "Claude receives the complete messages in range and declining preserves the release"
    else
        record_fail "expected the draft from both commit bodies before declining"
    fi

    PATH="$SANDBOX/bin:$PATH" WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" --dry-run
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *"$notes"*'>> dry run'* ]] && [[ "$OUT" != *'Publish v0.1.1?'* ]] \
       && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$RELEASE_TEST_PUSH_ARGS" ]; then
        record_pass "dry-run shows the generated draft without publication"
    else
        record_fail "expected a read-only preview of the generated draft"
    fi

    local reply
    for reply in failure blank malformed reference; do
        PATH="$SANDBOX/bin:$PATH" RELEASE_TEST_REPLY="$reply" WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" <<< N
        if [ "$RC" -ne 0 ] && [[ "$OUT" != *'Publish v0.1.1?'* ]] \
           && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$RELEASE_TEST_PUSH_ARGS" ]; then
            record_pass "Claude $reply stops before confirmation"
        else
            record_fail "expected Claude $reply to stop before approval"
        fi
    done

    printf '%s\trefs/tags/v0.1.0\n' "$(head_of "$repo")" > "$RELEASE_TEST_REMOTE_TAGS"
    rm -f "$RELEASE_TEST_INPUT"
    PATH="$SANDBOX/bin:$PATH" WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" <<< N
    if [ "$RC" -ne 0 ] && [ ! -e "$RELEASE_TEST_INPUT" ] && [ "$(snapshot "$repo")" = "$old" ] \
       && [[ "$OUT" != *'Publish v0.1.1?'* ]]; then
        record_pass "empty release range stops before calling Claude"
    else
        record_fail "expected no proposal for an empty range"
    fi
    printf '%s\trefs/tags/v0.1.0\n' "$base" > "$RELEASE_TEST_REMOTE_TAGS"

    git -C "$repo" tag v0.0.9 "$base"
    git -C "$repo" tag v9.0.0 "$(git -C "$repo" commit-tree 'HEAD^{tree}' -m 'separate history')"
    WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" --dry-run
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *'Commits since local v0.0.9'*"$notes"* ]] \
       && ! grep -Fq 'seed the fixture' "$RELEASE_TEST_INPUT"; then
        record_pass "offline preview drafts from the latest reachable local version tag"
    else
        record_fail "expected to exclude earlier history in the offline draft"
    fi
    old="$(snapshot "$repo")"
    rm -f "$RELEASE_TEST_INPUT"

    PATH="$SANDBOX/bin:$PATH" RELEASE_TEST_REPLY=failure WEGA_RELEASE_LOCAL_ONLY=0 \
        run_release "$repo" --notes "$RELEASE_TEST_NOTES" <<< N
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *"$notes"*'Publish v0.1.1?'* ]] \
       && [ ! -e "$RELEASE_TEST_INPUT" ] && [ "$(snapshot "$repo")" = "$old" ]; then
        record_pass "explicit notes are previewed without invoking Claude"
    else
        record_fail "expected to review the manual notes verbatim"
    fi

    PATH="$SANDBOX/bin:$PATH" WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" <<< Y
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *"$notes"*'Publish v0.1.1?'* ]] \
       && [ "$(section "$repo" 0.1.1)" = "$notes" ] && [ "$(git -C "$repo" log -1 --format=%b)" = "$notes" ] \
       && [ -f "$RELEASE_TEST_PUSH_ARGS" ] && [ "$(git -C "$repo" rev-parse 'v0.1.1^{commit}')" = "$(head_of "$repo")" ]; then
        record_pass "Y publishes the exact preview in the release commit and changelog"
    else
        record_fail "expected the reviewed draft in the published commit and changelog"
    fi
}

check_publication() {
    local repo old commit tag git_bin="$SANDBOX/bin" push_args="$SANDBOX/push-args"
    printf 'automatic release publication\n'
    local name
    for name in implicit explicit; do
        repo="$(make_repo "$name" $'### Fixed\n- a')"
        old="$(head_of "$repo")"
        git -C "$repo" update-ref refs/remotes/origin/main "$old"
        local args=()
        if [ "$name" = explicit ]; then args=(patch); fi
        rm -f "$push_args"
        PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" WEGA_RELEASE_LOCAL_ONLY=0 \
            run_release "$repo" ${args[@]+"${args[@]}"} <<< yes
        commit="$(head_of "$repo")"
        tag="$(git -C "$repo" rev-parse --verify 'refs/tags/v0.1.1^{commit}' 2>/dev/null)"
        if [ "$RC" -eq 0 ] && [ "$(version_of "$repo")" = 0.1.1 ] \
           && [ "$commit" != "$old" ] && [ "$tag" = "$commit" ] \
           && [ -f "$push_args" ] \
           && [[ "$OUT" == *'feat: seed the fixture'*'Publish v0.1.1? [y/N]'*'>> bumped '* ]] \
           && diff "$push_args" <(printf '%s\n' push --atomic --no-follow-tags origin \
               "$commit:refs/heads/main" refs/tags/v0.1.1:refs/tags/v0.1.1); then
            record_pass "$name patch pushes only the release commit and its tag, atomically"
        else
            record_fail "$name patch (exit $RC): $OUT"
        fi
    done

    repo="$(make_repo publish-dry-run $'### Fixed\n- a')"
    old="$(snapshot "$repo")"
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    rm -f "$push_args"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" WEGA_RELEASE_LOCAL_ONLY=0 \
        run_release "$repo" --dry-run
    if [ "$RC" -eq 0 ] && [ "$(snapshot "$repo")" = "$old" ] \
       && [ ! -e "$push_args" ] \
       && [[ "$OUT" == *'0.1.0 -> 0.1.1 (patch)'*'feat: seed the fixture'*'>> dry run'* ]] \
       && [[ "$OUT" != *'Publish v0.1.1?'* ]]; then
        record_pass "dry-run previews the default patch without publishing or changing files"
    else
        record_fail "dry-run (exit $RC): $OUT"
    fi

    repo="$(make_repo publish-rejected $'### Fixed\n- a')"
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" RELEASE_TEST_PUSH_STATUS=1 \
        WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" patch --yes </dev/null
    tag="$(git -C "$repo" rev-parse --verify 'refs/tags/v0.1.1^{commit}' 2>/dev/null)"
    if [ "$RC" -ne 0 ] && [ -f "$push_args" ] && [ "$tag" = "$(head_of "$repo")" ] \
       && [ -z "$(dirty_of "$repo")" ] && grep -Fq 'Retry the same push' <<<"$OUT" \
       && [[ "$OUT" != *'Publish v0.1.1?'* ]]; then
        record_pass "failed push keeps the commit and tag for retry without another version bump"
    else
        record_fail "failed push (exit $RC): $OUT"
    fi

    repo="$(make_repo fetch-failed $'### Fixed\n- a')"
    old="$(snapshot "$repo")"
    rm -f "$push_args"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" RELEASE_TEST_FETCH_STATUS=1 \
        WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" patch
    if [ "$RC" -ne 0 ] && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$push_args" ]; then
        record_pass "failed fetch stops publication before any release changes"
    else
        record_fail "failed fetch (exit $RC): $OUT"
    fi

    repo="$(make_repo explicit-empty $'### Fixed\n- a')"
    old="$(snapshot "$repo")"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" WEGA_RELEASE_LOCAL_ONLY=0 \
        run_release "$repo" ''
    if [ "$RC" -eq 2 ] && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$push_args" ]; then
        record_pass "an explicitly empty version is a usage error"
    else
        record_fail "empty version (exit $RC): $OUT"
    fi

    repo="$(make_repo notes-option $'### Fixed\n- a')"
    write_notes "$repo/--dry-run" $'### Fixed\n- a'
    old="$(snapshot "$repo")"
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" WEGA_RELEASE_LOCAL_ONLY=0 \
        run_release "$repo" --notes --dry-run
    if [ "$RC" -eq 2 ] && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$push_args" ]; then
        record_pass "a missing notes path cannot consume the dry-run option"
    else
        record_fail "missing notes path (exit $RC): $OUT"
    fi

    repo="$(make_repo publish-local-only $'### Fixed\n- a')"
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    rm -f "$push_args"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" \
        run_local_release "$repo" 0.1.1
    if [ "$RC" -eq 0 ] && [ "$(tags_of "$repo")" = v0.1.1 ] \
       && [ ! -e "$push_args" ] && grep -Fq 'git push --atomic origin main v0.1.1' <<<"$OUT" \
       && [[ "$OUT" != *'Publish v0.1.1?'* ]]; then
        record_pass "local-only release preserves the separate approved push"
    else
        record_fail "local-only release (exit $RC): $OUT"
    fi

    repo="$(make_repo publish-preview $'### Fixed\n- a')"
    local base other remote_tags="$SANDBOX/release-tags"
    base="$(head_of "$repo")"
    other="$(git -C "$repo" commit-tree 'HEAD^{tree}' -m 'different branch')"
    git -C "$repo" commit --allow-empty -qm 'feat: include this already pushed commit'
    git -C "$repo" tag -a v0.1.0 -m 'Local-only version'
    git -C "$repo" commit --allow-empty -qm 'fix: include the current tip'
    git -C "$repo" update-ref refs/remotes/origin/main "$(head_of "$repo")"
    printf '%s\t%s\n' "$other" refs/tags/v0.9.0 \
        0000000000000000000000000000000000000000 refs/tags/v0.0.9 \
        "$base" 'refs/tags/v0.0.9^{}' > "$remote_tags"
    old="$(snapshot "$repo")"
    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" RELEASE_TEST_REMOTE_TAGS="$remote_tags" \
        WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" patch <<< no
    if [ "$RC" -eq 0 ] && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$push_args" ] \
       && [[ "$OUT" == *'Commits since v0.0.9'*'fix: include the current tip'*'feat: include this already pushed commit'*'Publish v0.1.1? [y/N]'*'>> release cancelled'* ]] \
       && [[ "$OUT" != *'feat: seed the fixture'* ]]; then
        record_pass "the preview uses the reachable origin tag and declining leaves the release untouched"
    else
        record_fail "release preview and decline (exit $RC): $OUT"
    fi

    PATH="$git_bin:$PATH" RELEASE_TEST_PUSH_ARGS="$push_args" RELEASE_TEST_REMOTE_TAGS="$remote_tags" \
        WEGA_RELEASE_LOCAL_ONLY=0 run_release "$repo" patch </dev/null
    if [ "$RC" -ne 0 ] && [ "$(snapshot "$repo")" = "$old" ] && [ ! -e "$push_args" ] \
       && [[ "$OUT" == *'confirmation required'* ]]; then
        record_pass "missing input cannot approve publication"
    else
        record_fail "missing confirmation (exit $RC): $OUT"
    fi
}

check_release_body() {
    local fixture="$SANDBOX/release-body" step="$SANDBOX/create-release.sh"
    mkdir -p "$fixture/bin"
    ruby -ryaml -e '
        steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("release").fetch("steps")
        puts steps.find { |s| s["name"] == "Create GitHub Release" }.fetch("run")
    ' "$ROOT/.github/workflows/release.yml" > "$step" || { record_fail "missing release workflow step"; return; }
    cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
[[ "$1 $2 $3" == "release create v0.1.0" ]]
while [ "$#" -gt 0 ] && [ "$1" != --notes-file ]; do shift; done
cp "$2" "$RUNNER_TEMP/api-body"
GH
    chmod +x "$fixture/bin/gh"
    printf '%s\n' '### Added' '- Select pending items.  ' '' '### Fixed' '- Selection survives a refresh.' > "$fixture/approved"
    local history
    for history in first later; do
        {
            printf '## [Unreleased]\n\n## [0.1.0] — 2026-01-01\n\n'
            cat "$fixture/approved"
            printf '\n'
            if [ "$history" = later ]; then printf '## [0.0.9] — 2025-12-01\n\n- Older change.\n\n'; fi
            printf '[Unreleased]: https://example.invalid/compare/v0.1.0...HEAD\n'
        } > "$fixture/CHANGELOG.md"
        if (cd "$fixture" && PATH="$fixture/bin:$PATH" RUNNER_TEMP="$fixture" STABLE_RELEASE=true \
                GITHUB_REF_NAME=v0.1.0 /bin/bash -eu "$step") && cmp -s "$fixture/approved" "$fixture/api-body"; then
            record_pass "$history stable release sends the exact approved Markdown to GitHub"
        else
            record_fail "$history stable release body differs from the approved Markdown"
        fi
    done
}

if [ "${1-}" = "--release-body-unit" ]; then
    check_release_body
    exit "$((failures != 0))"
fi

mkdir -p "$SANDBOX/claude-bin"
cat > "$SANDBOX/claude-bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
set -eu
[[ "$1" == -p && " $* " == *' --safe-mode '* && " $* " == *' --output-format text '* ]] || exit 2
while [ "$#" -gt 0 ] && [ "$1" != --tools ]; do shift; done
[ "$#" -ge 2 ] && [ -z "$2" ] || exit 2
cat > "${RELEASE_TEST_INPUT:-/dev/null}"
case "${RELEASE_TEST_REPLY:-ok}" in
    failure) echo 'partial draft'; exit 1 ;;
    blank) printf '   \n' ;;
    malformed) echo '## Accidental release heading' ;;
    reference) printf '%s\n' '- An inline link' '[settings]: https://example.invalid' ;;
    ok)
        if [ -n "${RELEASE_TEST_NOTES:-}" ]; then cat "$RELEASE_TEST_NOTES"; else echo '- Draft from commits'; fi
        ;;
esac
CLAUDE
chmod +x "$SANDBOX/claude-bin/claude"
stub_remote_git
if [ "${1-}" = "--reviewed-notes-unit" ]; then
    check_reviewed_notes
    exit "$((failures != 0))"
fi

check_publication
if [ "${1-}" = "--publication-unit" ]; then
    exit "$((failures != 0))"
fi

check_reviewed_notes

check_release_body

# --- 1 ------------------------------------------------------------------------
printf 'notes file published verbatim\n'
repo="$(make_repo verbatim '')"
notes="$SANDBOX/verbatim-notes.md"
cat > "$notes" <<'NOTES'
Podsumowanie z $HOME, \1, & oraz 100% i `słowem`.

### Added
- **A.** b

### Known issues
- c
NOTES
run_local_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 0 ]; then
    if diff <(section "$repo" 0.2.0) <(trim_blanks "$notes") >/dev/null; then
        record_pass "section equals the notes file"
    else
        record_fail "section differs from the notes file"
        diff <(section "$repo" 0.2.0) <(trim_blanks "$notes") >&2 || true
    fi
    if grep -qxF "## [0.2.0] — $(date +%Y-%m-%d)" "$repo/CHANGELOG.md"; then
        record_pass "heading carries today's date"
    else
        record_fail "heading '## [0.2.0] — $(date +%Y-%m-%d)' not found"
    fi
else
    record_fail "release.sh exited $RC: $OUT"
fi
verbatim_repo="$repo"
verbatim_out="$OUT"

# --- 2 ------------------------------------------------------------------------
printf '[Unreleased] is the prepared source for a local cut without --notes\n'
repo="$(make_repo fromunreleased $'### Fixed\n- a')"
run_local_release "$repo" 0.2.0
if [ "$RC" -eq 0 ] && [ "$(section "$repo" 0.2.0)" = $'### Fixed\n- a' ]; then
    record_pass "section equals the [Unreleased] body"
else
    record_fail "section not taken from [Unreleased] (exit $RC): $(section "$repo" 0.2.0)"
fi
if [ -z "$(unreleased_body "$repo")" ]; then
    record_pass "[Unreleased] is empty afterwards"
else
    record_fail "[Unreleased] still holds: $(unreleased_body "$repo")"
fi

# --- 3 ------------------------------------------------------------------------
printf -- '--notes supersedes [Unreleased]\n'
repo="$(make_repo supersede $'### Fixed\n- old')"
notes="$SANDBOX/supersede-notes.md"
write_notes "$notes" $'### Fixed\n- new'
run_local_release "$repo" 0.2.0 --notes "$notes"
body="$(section "$repo" 0.2.0)"
if [ "$RC" -eq 0 ] && grep -q -- '- new' <<<"$body" && ! grep -q -- '- old' <<<"$body"; then
    record_pass "section holds the notes, not the old body"
else
    record_fail "wrong section (exit $RC): $body"
fi
if [ -z "$(unreleased_body "$repo")" ]; then
    record_pass "[Unreleased] emptied"
else
    record_fail "[Unreleased] still holds: $(unreleased_body "$repo")"
fi
if grep -q 'supersedes 2 line(s)' <<<"$OUT"; then
    record_pass "output reports the superseded line count"
else
    record_fail "no 'supersedes 2 line(s)' in: $OUT"
fi

# --- 4 ------------------------------------------------------------------------
printf 'empty notes refused\n'
repo="$(make_repo emptynotes '')"
before="$(snapshot "$repo")"
run_local_release "$repo" 0.2.0
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
    record_pass "empty [Unreleased] refused, nothing changed"
else
    record_fail "empty [Unreleased] (exit $RC) or state changed"
fi
notes="$SANDBOX/blank-notes.md"
printf '   \n\n  \t\n' > "$notes"
run_local_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ] && grep -qF 'the release notes are empty' <<<"$OUT"; then
    record_pass "whitespace-only notes refused, nothing changed"
else
    record_fail "whitespace-only notes (exit $RC) or state changed"
fi

# --- 5 ------------------------------------------------------------------------
printf "'## ' line refused\n"
repo="$(make_repo h2 '')"
notes="$SANDBOX/h2-notes.md"
write_notes "$notes" $'### Fixed\n- a\n\n## [0.1.9]\n- b'
before="$(snapshot "$repo")"
run_local_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ] && [ "$(version_of "$repo")" = "0.1.0" ] \
   && grep -qF "contain a line starting with '## ':" <<<"$OUT"; then
    record_pass "notes with a '## ' line refused, nothing written"
else
    record_fail "'## ' line (exit $RC) or state changed"
fi

# --- 6 ------------------------------------------------------------------------
printf 'commit and tag\n'
repo="$verbatim_repo"
files="$(git -C "$repo" show --name-only --format= HEAD | sort | paste -sd, -)"
if [ "$files" = "CHANGELOG.md,$VERSION_FILE" ]; then
    record_pass "commit contains exactly the two release files"
else
    record_fail "commit files: $files"
fi
if [ "$(git -C "$repo" log -1 --format=%s)" = "chore(release): v0.2.0" ]; then
    record_pass "commit subject"
else
    record_fail "commit subject: $(git -C "$repo" log -1 --format=%s)"
fi
if [ "$(git -C "$repo" cat-file -t refs/tags/v0.2.0 2>/dev/null)" = "tag" ]; then
    record_pass "tag is annotated"
else
    record_fail "v0.2.0 is not an annotated tag"
fi
if [ "$(git -C "$repo" rev-parse 'v0.2.0^{commit}' 2>/dev/null)" = "$(head_of "$repo")" ]; then
    record_pass "tag points at HEAD"
else
    record_fail "tag does not point at HEAD"
fi
if [ "$(version_of "$repo")" = "0.2.0" ]; then
    record_pass "version expression reads 0.2.0"
else
    record_fail "version reads '$(version_of "$repo")'"
fi
if grep -qF 'git push --atomic origin main v0.2.0' <<<"$verbatim_out"; then
    record_pass "output prints the atomic push"
else
    record_fail "no atomic push line in: $verbatim_out"
fi

# --- 7 ------------------------------------------------------------------------
printf 'ahead of origin allowed\n'
repo="$(make_repo ahead '### Fixed
- a' origin)"
printf 'x\n' > "$repo/extra.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: local only"
run_release "$repo" 0.2.0 --yes
origin="$SANDBOX/ahead.git"
if [ "$RC" -eq 0 ] && [ "$(git -C "$origin" cat-file -t refs/tags/v0.2.0 2>/dev/null)" = "tag" ] \
   && [ "$(git -C "$origin" rev-parse refs/heads/main)" = "$(head_of "$repo")" ] \
   && [ "$(git -C "$origin" rev-parse 'refs/tags/v0.2.0^{commit}')" = "$(head_of "$repo")" ]; then
    record_pass "release pushed while ahead of origin"
else
    record_fail "ahead of origin (exit $RC): $OUT"
fi

# --- 8 ------------------------------------------------------------------------
printf 'behind origin refused\n'
repo="$(make_repo behind '### Fixed
- a' origin)"
git clone -q -b main "$SANDBOX/behind.git" "$SANDBOX/behind-other"
git -C "$SANDBOX/behind-other" config user.email guard@example.invalid
git -C "$SANDBOX/behind-other" config user.name  "Release Guard"
git -C "$SANDBOX/behind-other" config core.hooksPath /dev/null
printf 'y\n' > "$SANDBOX/behind-other/y.txt"
git -C "$SANDBOX/behind-other" add -A
git -C "$SANDBOX/behind-other" commit -q -m "feat: remote only"
git -C "$SANDBOX/behind-other" push -q origin main
run_release "$repo" 0.2.0
if [ "$RC" -eq 1 ] && [ -z "$(tags_of "$repo")" ]; then
    record_pass "refused, no tag"
else
    record_fail "behind origin (exit $RC), tags: $(tags_of "$repo")"
fi

# --- 9 ------------------------------------------------------------------------
printf 'existing tag refused\n'
repo="$(make_repo tagged '### Fixed
- a')"
git -C "$repo" tag v0.2.0
before="$(snapshot "$repo")"
run_release "$repo" 0.2.0
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
    record_pass "existing tag refused"
else
    record_fail "existing tag (exit $RC) or state changed"
fi

# --- 10 -----------------------------------------------------------------------
printf 'version not greater refused\n'
repo="$(make_repo notgreater '### Fixed
- a')"
before="$(snapshot "$repo")"
run_release "$repo" 0.1.0
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
    record_pass "0.1.0 refused over 0.1.0"
else
    record_fail "not-greater version (exit $RC) or state changed"
fi

# --- 11 -----------------------------------------------------------------------
printf -- '--dry-run writes nothing\n'
repo="$(make_repo dryrun '### Fixed
- a')"
before="$(snapshot "$repo")"
run_release "$repo" 0.2.0 --dry-run
if [ "$RC" -eq 0 ] && [ "$(snapshot "$repo")" = "$before" ]; then
    record_pass "dry run exits 0 and changes nothing"
else
    record_fail "dry run (exit $RC) or state changed"
fi

# --- 12 -----------------------------------------------------------------------
printf 'link references\n'
older=$'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- a\n\n## [0.1.0] — 2026-01-01\n\n### Added\n- first\n'
repo="$(make_repo linkstagged '')"
set_changelog "$repo" "$older"
git -C "$repo" remote add origin https://example.invalid/o/r.git
git -C "$repo" tag -a v0.1.0 -m "0.1.0"
run_local_release "$repo" 0.2.0
if [ "$RC" -eq 0 ] \
   && grep -qxF '[0.2.0]: https://example.invalid/o/r/compare/v0.1.0...v0.2.0' "$repo/CHANGELOG.md" \
   && grep -qxF '[Unreleased]: https://example.invalid/o/r/compare/v0.2.0...HEAD' "$repo/CHANGELOG.md"; then
    record_pass "tagged predecessor gets a compare link"
else
    record_fail "tagged predecessor links wrong (exit $RC): $(grep '^\[' "$repo/CHANGELOG.md")"
fi
repo="$(make_repo linksuntagged '')"
set_changelog "$repo" "$older"
git -C "$repo" remote add origin https://example.invalid/o/r.git
run_local_release "$repo" 0.2.0
if [ "$RC" -eq 0 ] \
   && grep -qxF '[0.2.0]: https://example.invalid/o/r/releases/tag/v0.2.0' "$repo/CHANGELOG.md" \
   && grep -qxF '[Unreleased]: https://example.invalid/o/r/compare/v0.2.0...HEAD' "$repo/CHANGELOG.md"; then
    record_pass "untagged predecessor gets a release-tag link"
else
    record_fail "untagged predecessor links wrong (exit $RC): $(grep '^\[' "$repo/CHANGELOG.md")"
fi

# --- 13 -----------------------------------------------------------------------
printf 'removed modes are usage errors\n'
repo="$(make_repo removed '### Fixed
- a')"
for mode in --continue --abort; do
    run_release "$repo" "$mode"
    if [ "$RC" -eq 2 ]; then
        record_pass "$mode exits 2"
    else
        record_fail "$mode exited $RC"
    fi
done
run_release "$repo" 0.2.0 --notes "" --dry-run
if [ "$RC" -eq 2 ]; then
    record_pass "--notes with an empty value exits 2"
else
    record_fail "--notes with an empty value exited $RC"
fi

# --- 14 -----------------------------------------------------------------------
printf 'no trailing newline\n'
repo="$(make_repo nonewline '')"
set_changelog "$repo" $'# Changelog\n\n## [Unreleased]\n\n## [0.1.0] — 2026-01-01\n\n### Added\n- first\n'
notes="$SANDBOX/nonewline-notes.md"
printf '### Fixed\n- a' > "$notes"
run_local_release "$repo" 0.2.0 --notes "$notes"
last_entry="$(grep -n -x -- '- a' "$repo/CHANGELOG.md" | head -1 | cut -d: -f1)"
after_entry="$(sed -n "$((${last_entry:-0} + 1))p" "$repo/CHANGELOG.md")"
after_blank="$(sed -n "$((${last_entry:-0} + 2))p" "$repo/CHANGELOG.md")"
if [ "$RC" -eq 0 ] && [ -z "$after_entry" ] && [[ "$after_blank" == "## [0.1.0]"* ]]; then
    record_pass "a blank line separates the section from the older release"
else
    record_fail "section runs into the next heading (exit $RC): '$after_entry' / '$after_blank'"
fi

# --- 15 -----------------------------------------------------------------------
printf 'relative --notes from a subdirectory\n'
repo="$(make_repo relative '')"
write_notes "$repo/notes.md" $'### Fixed\n- rel'
git -C "$repo" add -A
git -C "$repo" commit -q -m "docs: notes fixture"
run_local_release "$repo/Sources" 0.2.0 --notes ../notes.md
if [ "$RC" -eq 0 ] && diff <(section "$repo" 0.2.0) <(trim_blanks "$repo/notes.md") >/dev/null; then
    record_pass "path resolved against the caller's directory"
else
    record_fail "relative notes (exit $RC): $OUT"
fi

# --- 16 -----------------------------------------------------------------------
printf 'missing [Unreleased] refused\n'
repo="$(make_repo nounreleased '')"
set_changelog "$repo" $'# Changelog\n\n## [0.1.0] — 2026-01-01\n\n### Added\n- first\n'
notes="$SANDBOX/nounreleased-notes.md"
write_notes "$notes" $'### Fixed\n- a'
before="$(snapshot "$repo")"
run_local_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ] && grep -qF "has no '## [Unreleased]' heading" <<<"$OUT"; then
    record_pass "refused, nothing written"
else
    record_fail "missing [Unreleased] (exit $RC) or state changed"
fi

# --- 17 -----------------------------------------------------------------------
# Skill wydania wywołuje skrypt i push dokładnie w formie, którą przyjmują release.sh
# i hook git-guard: bez usuniętych trybów i bez pushu w innej formie niż
# `git push --atomic origin main vX.Y.Z` (hook wpuszcza tylko tę, bez łańcucha i bez -C).
#
# Wypisuje linie spoza bloków ```text, w których po `git` pada `push`, a które nie są
# dokładnie tym pushem: w bloku kodu cała linia, w prozie każdy fragment w backtickach.
# Bloki ```text to polecenia pokazywane właścicielowi do uruchomienia, nie przez skill.
stray_pushes() {
    awk '
        BEGIN { exact = "git push --atomic origin main vX.Y.Z"; open = 0 }
        match($0, /^[[:space:]]*```+/) {
            run = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", run)
            rest = substr($0, RSTART + RLENGTH)
            if (!open) { open = length(run); lang = rest; next }
            if (length(run) >= open && rest ~ /^[[:space:]]*$/) { open = 0; next }
        }
        open && lang ~ /^text/ { next }
        open {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /(^|[^[:alnum:]_-])git[[:space:]].*push/ && line != exact) print NR ": " $0
            next
        }
        {
            line = $0
            gsub("`" exact "`", "", line)
            if (line ~ /(^|[^[:alnum:]_-])git[[:space:]][^`]*push/) print NR ": " $0
        }
    ' "$1"
}

printf 'skill calls what the script and hook accept\n'
skill="$ROOT/.claude/skills/release/SKILL.md"
if [ ! -f "$skill" ]; then
    record_fail "SKILL.md missing: $skill"
else
    absent=""
    for needle in "WEGA_RELEASE_LOCAL_ONLY=1 ./scripts/release.sh X.Y.Z --notes 'NOTES'" '--dry-run' 'git push --atomic origin main v'; do
        grep -qF -- "$needle" "$skill" || absent="$absent '$needle'"
    done
    if [ -z "$absent" ]; then
        record_pass "cuts the approved release locally before the separate atomic push"
    else
        record_fail "SKILL.md lacks:$absent"
    fi
    if grep -qF -- '--continue' "$skill"; then
        record_fail "SKILL.md uses the removed --continue mode"
    elif grep -qE -- 'git -C [^ ]* push' "$skill"; then
        record_fail "SKILL.md pushes with git -C, which the hook denies"
    else
        record_pass "no removed mode, no git -C push"
    fi
    stray="$(stray_pushes "$skill")"
    if [ -z "$stray" ]; then
        record_pass "every push outside text blocks is exactly the release push"
    else
        record_fail "SKILL.md pushes in a form the hook denies: $stray"
    fi
fi

echo
if [ "$failures" -ne 0 ]; then
    echo "test-release-guard: $failures failure(s)" >&2
    exit 1
fi
echo "test-release-guard: ok"
