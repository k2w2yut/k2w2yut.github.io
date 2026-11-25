#!/usr/bin/env bash
# Tests for privacy-gate.sh. Each test builds a throwaway git repo and runs the gate on it.
set -uo pipefail
GATE="$(cd "$(dirname "$0")" && pwd)/privacy-gate.sh"
export GATE_SKIP_BUILD=1 LC_ALL=en_US.UTF-8
pass=0; fail=0

# repo <file> <content> [commit message] -> prints repo path; origin/master = parent of HEAD
repo() {
  local d; d=$(mktemp -d)
  (
    cd "$d" && git init -q && git config user.email t@t && git config user.name t
    echo base > README.md && git add . && git commit -qm base
    git update-ref refs/remotes/origin/master HEAD
    mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1" && git add . && git commit -qm "${3:-add}"
  )
  echo "$d"
}
# repo2 <file> <content1> <content2>: commit 1 adds content1, commit 2 replaces it with content2
repo2() {
  local d; d=$(repo "$1" "$2")
  ( cd "$d" && printf '%s\n' "$3" > "$1" && git commit -qam second )
  echo "$d"
}
names() { local f; f=$(mktemp); printf '%s\n' "$@" > "$f"; echo "$f"; }

check() { # name expected_exit expected_stdout_substring repo names [extra args]
  local name=$1 want=$2 grepfor=$3 r=$4 n=$5; shift 5
  local out code
  out=$(cd "$r" && bash "$GATE" --names "$n" "$@" 2>&1); code=$?
  if [[ $code == "$want" && ( -z $grepfor || $out == *"$grepfor"* ) ]]; then
    echo "PASS $name"; pass=$((pass+1))
  else
    echo "FAIL $name (exit $code, want $want)"; echo "$out" | sed 's/^/    /'; fail=$((fail+1))
  fi
}

check clean_pass 0 "" "$(repo _posts/x.md 'a hospital group')" "$(names 'Acme Hospital')"
check case_insensitive_hit 1 "HIT Acme" "$(repo _posts/x.md "see ACME's portal")" "$(names '# comment' '' 'Acme')"
check svg_metadata_hit 1 "HIT Acme" "$(repo assets/diagrams/p/a.svg '<svg><metadata>acme</metadata></svg>')" "$(names Acme)"
check filename_hit 1 "HIT acme" "$(repo assets/diagrams/acme-flow.svg '<svg/>')" "$(names acme)"
check commit_message_hit 1 "HIT Acme" "$(repo _posts/x.md 'clean' 'fix for Acme')" "$(names Acme)"
check utf8_hit 1 "HIT ทดสอบ" "$(repo _posts/x.md 'ที่ ทดสอบ')" "$(names 'ทดสอบ')"
check short_term_no_substring 0 "" "$(repo _posts/x.md 'a factory plan')" "$(names ACT)"
check short_term_word_hit 1 "HIT ACT" "$(repo _posts/x.md 'the act board')" "$(names ACT)"
check removed_in_later_commit_hit 1 "HIT Acme" "$(repo2 docs/plan.md 'see Acme here' 'see a hospital here')" "$(names Acme)"
check split_across_svg_text_hit 1 "HIT Acme Hospital" "$(repo assets/d/a.svg '<svg><text>Acme</text><text x="1">Hospital</text></svg>')" "$(names 'Acme Hospital')"
check split_across_lines_hit 1 "HIT Acme Hospital" "$(repo docs/spec.md $'the Acme\nHospital team')" "$(names 'Acme Hospital')"
check html_entity_hit 1 "HIT A&B" "$(repo assets/d/a.svg '<svg><text>A&amp;B</text></svg>')" "$(names 'A&B')"
check missing_names 2 "" "$(repo _posts/x.md clean)" /nonexistent

echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
