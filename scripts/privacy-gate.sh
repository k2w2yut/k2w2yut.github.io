#!/usr/bin/env bash
# Privacy gate: search what would be published for any term in a private name list.
# Usage: privacy-gate.sh [--history] [--names FILE] [--rev REV]
# Scans the committed tree of REV (not the working tree): every file path, every file's text,
# the Jekyll build of that tree, and the commit messages of origin/master..REV
# (with diffs, so a name added and removed again inside the range is caught;
# --history: every commit message and diff in the repository).
# Each text file is also scanned as a normalised copy (entities decoded, tags dropped, lines joined).
# Terms of 4 characters or fewer match as whole words only (ACT must not hit "factory").
# Exit: 0 no hit, 1 hit, 2 usage error or missing name list.
# Env: GATE_SKIP_BUILD=1 skips the Jekyll build; GATE_KEEP=1 keeps the temp folder (last line "KEPT <path>").
set -euo pipefail
export LC_ALL=en_US.UTF-8

names="$HOME/Developer/2026/research-blog/names.txt"
rev=HEAD
history=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --names) names=${2:?}; shift 2 ;;
    --rev) rev=${2:?}; shift 2 ;;
    --history) history=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -r $names ]] || { echo "name list not found: $names" >&2; exit 2; }

tmp=$(mktemp -d)
cleanup() { if [[ ${GATE_KEEP:-0} == 1 ]]; then echo "KEPT $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT

# Terms: drop comments and blank lines (an empty pattern would match everything).
terms=()
while IFS= read -r t; do t=$(printf '%s' "$t" | tr -s '[:space:]' ' '); terms+=("$t"); done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$names")
[[ ${#terms[@]} -gt 0 ]] || { echo "name list is empty: $names" >&2; exit 2; }

mkdir "$tmp/src" "$tmp/text"
git archive "$rev" | tar -x -C "$tmp/src"
git ls-tree -r --name-only "$rev" > "$tmp/text/paths.txt"
if [[ $history == 1 ]]; then
  git log -p --all --format='commit %H%n%B' > "$tmp/text/history.txt"
elif git rev-parse -q --verify origin/master >/dev/null; then
  git log -p --format='commit %H%n%B' "origin/master..$rev" > "$tmp/text/commits.txt"
else
  git log -p --format='commit %H%n%B' "$rev" > "$tmp/text/commits.txt"
fi

if [[ ${GATE_SKIP_BUILD:-0} != 1 ]]; then
  [[ -x $HOME/.rbenv/versions/3.4.1/bin/ruby ]] && export PATH="$HOME/.rbenv/versions/3.4.1/bin:$PATH"
  export BUNDLE_PATH="${BUNDLE_PATH:-$HOME/.cache/k2w2-blog-bundle}" BUNDLE_GEMFILE="$tmp/src/Gemfile"
  ( cd "$tmp/src" && bundle _2.7.1_ install --quiet && bundle _2.7.1_ exec jekyll build -q -d "$tmp/site" ) \
    > "$tmp/build.log" 2>&1 || { echo "jekyll build failed:" >&2; tail -20 "$tmp/build.log" >&2; exit 2; }
  rm "$tmp/build.log"
fi

# Normalised copy of every text file: decode HTML entities, drop tags, join lines, collapse
# whitespace. This catches a name split across lines or SVG <text> elements, or written as &amp;.
python3 -I - "$tmp" <<'PY'
import html, os, re, sys
root = sys.argv[1]; out = os.path.join(root, "norm")
for d, _, files in os.walk(root):
    if d.startswith(out):
        continue
    for f in files:
        p = os.path.join(d, f)
        try:
            t = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        t = re.sub(r"<[^>]*>", " ", t)
        t = html.unescape(html.unescape(t))
        t = re.sub(r"\s+", " ", t)
        q = os.path.join(out, os.path.relpath(p, root))
        os.makedirs(os.path.dirname(q), exist_ok=True)
        open(q, "w", encoding="utf-8").write(t)
PY

hits=0
for t in "${terms[@]}"; do
  while IFS= read -r f; do
    echo "HIT $t ${f#"$tmp/"}"; hits=1
  done < <(if [[ ${#t} -le 4 ]]; then grep -rliwF -- "$t" "$tmp"; else grep -rliF -- "$t" "$tmp"; fi || true)
done
[[ $hits == 0 ]] && echo "privacy gate: no hit (${#terms[@]} terms, rev $rev)"
exit $hits
