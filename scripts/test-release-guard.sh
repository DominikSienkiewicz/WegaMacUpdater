#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-release-guard.sh — test regresyjny jednofazowego `release.sh`.
#
# Zastępuje dwa dawne guardy: REL-06 (baseline) i REL-07 (nagłówki). REL-06 testował
# wyszukiwanie „poprzedniego wydania” w historii commitów —
# funkcję, której już nie ma, bo historię czyta skill, a nie skrypt. Intencja REL-07
# (nigdy nie zgubić ani nie przekręcić ręcznie napisanego tekstu) przeżyła jako
# „notatki są kopiowane dosłownie”.
#
# Notatki wydania stają się opisem GitHub Release bez żadnej dalszej obróbki, więc
# skrypt ma je przepisać bajt w bajt (poza obciętymi pustymi liniami na brzegach),
# odmówić tego, czego przepisać nie może, i niczego nie wypychać.
#
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
    OUT="$(cd "$dir" && "$RELEASE_SH" "$@" 2>&1)"
    RC=$?
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
run_release "$repo" 0.2.0 --notes "$notes"
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
printf '[Unreleased] is the source without --notes\n'
repo="$(make_repo fromunreleased $'### Fixed\n- a')"
run_release "$repo" 0.2.0
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
run_release "$repo" 0.2.0 --notes "$notes"
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
run_release "$repo" 0.2.0
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
    record_pass "empty [Unreleased] refused, nothing changed"
else
    record_fail "empty [Unreleased] (exit $RC) or state changed"
fi
notes="$SANDBOX/blank-notes.md"
printf '   \n\n  \t\n' > "$notes"
run_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
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
run_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ] && [ "$(version_of "$repo")" = "0.1.0" ]; then
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
run_release "$repo" 0.2.0
if [ "$RC" -eq 0 ] && [ "$(git -C "$repo" cat-file -t refs/tags/v0.2.0 2>/dev/null)" = "tag" ]; then
    record_pass "release cut while ahead of origin"
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
run_release "$repo" 0.2.0
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
run_release "$repo" 0.2.0
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
run_release "$repo" 0.2.0 --notes "$notes"
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
run_release "$repo/Sources" 0.2.0 --notes ../notes.md
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
run_release "$repo" 0.2.0 --notes "$notes"
if [ "$RC" -eq 1 ] && [ "$(snapshot "$repo")" = "$before" ]; then
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
    for needle in './scripts/release.sh' '--notes' '--dry-run' 'git push --atomic origin main v'; do
        grep -qF -- "$needle" "$skill" || absent="$absent '$needle'"
    done
    if [ -z "$absent" ]; then
        record_pass "names release.sh, --notes, --dry-run and the atomic push"
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
