#!/usr/bin/env bash
# The action's tests: real git histories in temporary repositories, report-deploy.sh run against
# test/server.py, which checks signatures the way Viper does. Runs on bash 3.2 and later.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../report-deploy.sh"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE"
TOKEN="vdt_$(openssl rand -hex 24)"
printf '%s' "$TOKEN" > "$STATE/token"
failures=0
passes=0

python3 "$HERE/server.py" "$STATE" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do [[ -s "$STATE/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$STATE/port")"

# Every program the script runs goes through a shim that logs its arguments, so a test can check
# the token never reached one.
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"
for tool in git jq openssl curl od cat cut tr awk sed sort date mktemp chmod rm wc grep tail head seq; do
  real=$(command -v "$tool")
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/argv.log"\nexec "%s" "$@"\n' "$tool" "$STATE" "$real" > "$SHIMS/$tool"
  chmod +x "$SHIMS/$tool"
done

check() {
  local name=$1 actual=$2 expected=$3
  if [[ "$actual" == "$expected" ]]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# A repository with an origin, checked out at work/, with one commit.
new_repo() {
  rm -rf "$TMP/origin.git" "$TMP/work"
  git init -q --bare "$TMP/origin.git"
  git -c init.defaultBranch=main init -q "$TMP/work"
  cd "$TMP/work"
  git config user.email ci@harbor.test
  git config user.name CI
  git config commit.gpgsign false
  git remote add origin "$TMP/origin.git"
  c "Start"
}

c() { git commit -q --allow-empty -m "$1"; }
push() { git push -q origin "${1:-HEAD:refs/heads/main}" 2>/dev/null; }
latest() { printf '%s' "$1" > "$STATE/latest"; }

# Runs the action as Actions would, here, and keeps what it printed.
deploy() {
  rm -f "$STATE/body.json" "$STATE/headers.json" "$STATE/output"
  set +e
  env PATH="$SHIMS:$PATH" VIPER_URL="$URL" VIPER_ENVIRONMENT_ID=env-1 VIPER_DEPLOY_TOKEN="${DEPLOY_TOKEN:-$TOKEN}" \
    GITHUB_REPOSITORY=twinsunllc/harbor GITHUB_RUN_ID=9001 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=report_deploy GITHUB_RUN_NUMBER=412 \
    GITHUB_REF_NAME=main GITHUB_ACTOR=sam GITHUB_SERVER_URL=https://github.com GITHUB_OUTPUT="$STATE/output" RUNNER_TEMP="$TMP" \
    "$@" "$SCRIPT" > "$STATE/out" 2>&1
  status=$?
  set -e
}

body() { jq -c "$1" "$STATE/body.json"; }
prs() { body '[.pull_requests[].number]'; }
removed_prs() { body '[.removed_pull_requests[].number]'; }

echo "== The signature, the headers and the token"
new_repo
latest ""
deploy
check "a signed post is accepted" "$status" 0
check "the delivery is the run, the attempt and the job" "$(jq -r '."X-Viper-Delivery"' "$STATE/headers.json")" "9001-2-report_deploy"
check "the run is linked" "$(body .run_url)" '"https://github.com/twinsunllc/harbor/actions/runs/9001"'
check "the token never reached a program's arguments" "$(grep -cF "$TOKEN" "$STATE/argv.log" || true)" 0
DEPLOY_TOKEN="vdt_wrong" deploy
check "a wrong token fails the step" "$status" 1
check "and says so" "$(grep -c "Viper refused the signature" "$STATE/out")" 1
long="k$(openssl rand -hex 70)"
printf 'x' > "$TMP/msg"
check "a key longer than the block signs as openssl does" \
  "$(sed -n '/^pad_key()/,/^}/p;/^hmac_file()/,/^}/p' "$SCRIPT" > "$TMP/hmac.sh"; VIPER_DEPLOY_TOKEN="$long" WORK="$TMP" bash -c ". '$TMP/hmac.sh'; hmac_file '$TMP/msg'")" \
  "$(printf 'x' | openssl dgst -sha256 -hmac "$long" -r | cut -d' ' -f1)"

echo "== The first run"
deploy
check "sends only HEAD" "$(body .commit_shas)" "[\"$(git rev-parse HEAD)\"]"
check "with range_known false" "$(body .range_known)" false
check "and no fixes" "$(body '[.pull_requests, .jira_keys] | map(length)')" "[0,0]"

echo "== A normal range"
c "Merge pull request #329 from twinsunllc/old-work"
push; latest "$(git rev-parse HEAD)"
c "Merge pull request #330 from twinsunllc/feature/SETCO-921-crew-filter"
c "Fix the crew filter (SETCO-922 follow-up)"
c "Add the job count to the header SETCO-923 (#331)"
c "A plain commit about SETCO-924"
deploy
check "range_known" "$(body .range_known)" true
check "the merged and squashed PRs, oldest first" "$(prs)" "[330,331]"
check "keys from the branch and the squash subject only" "$(body .jira_keys)" '["SETCO-921","SETCO-923"]'
check "the commits since the last deploy" "$(body '.commit_shas | length')" 4
check "the repository on each PR" "$(body '.pull_requests[0].repository')" '"twinsunllc/harbor"'
check "nothing taken away" "$(removed_prs)" "[]"

echo "== A rollback, and another branch"
fix=$(git rev-parse HEAD)
git checkout -q -b rollback HEAD~4
latest "$fix"
deploy
check "a rollback adds nothing" "$(prs)" "[]"
check "and takes away what it left behind" "$(removed_prs)" "[330,331]"
check "and their keys" "$(body .removed_jira_keys)" '["SETCO-921","SETCO-923"]'
c "Hotfix the header (#340)"
deploy
check "another branch adds its own" "$(prs)" "[340]"
check "and takes away the other's" "$(removed_prs)" "[330,331]"
git checkout -q main

echo "== Reverts"
latest "$(git rev-parse HEAD)"
c 'Revert "Add the job count to the header SETCO-923 (#331)" (#341)'
c "Merge pull request #342 from twinsunllc/revert-330-feature/SETCO-921-crew-filter"
c 'Revert "Merge pull request #329 from twinsunllc/old-work"'
deploy
check "a revert adds nothing of its own" "$(prs)" "[]"
check "both revert forms take the PR away" "$(removed_prs)" "[331,330,329]"
check "and its keys" "$(body .removed_jira_keys)" '["SETCO-923","SETCO-921"]'
latest "$(git rev-parse HEAD)"
c "Merge pull request #350 from twinsunllc/SETCO-950-dates"
c "Merge pull request #351 from twinsunllc/revert-350-SETCO-950-dates"
c "Shorter labels (#352)"
deploy
check "merged and reverted in one range ends removed" "$(removed_prs)" "[350]"
check "the later commit wins" "$(prs)" "[352]"
check "keys follow it" "$(body '[.jira_keys, .removed_jira_keys]')" '[[],["SETCO-950"]]'

echo "== An unknown last commit"
latest "0123456789abcdef0123456789abcdef01234567"
deploy
check "still reports the deploy" "$status" 0
check "with range_known false" "$(body .range_known)" false
check "and warns" "$(grep -c "can't find the last deployed commit" "$STATE/out")" 1

echo "== A shallow clone"
new_repo
c "Merge pull request #400 from twinsunllc/first"
push; latest "$(git rev-parse HEAD)"
for n in 401 402 403; do c "Step $n (#$n)"; done
push
rm -rf "$TMP/shallow"
git clone -q --depth 1 "file://$TMP/origin.git" "$TMP/shallow"
cd "$TMP/shallow"
check "the clone starts shallow" "$(git rev-parse --is-shallow-repository)" true
deploy
check "fetches the history and reads the range" "$(body .range_known),$(prs)" "true,[401,402,403]"

echo "== The build's name"
new_repo
latest ""
deploy
check "falls back to the run number" "$(body .build)" '"412"'
git tag build-9
git tag build-10
deploy
check "takes the highest build tag at HEAD" "$(body .build)" '"10"'
git tag -d build-9 build-10 >/dev/null
c "Next"
git push -q origin HEAD:refs/heads/main
git tag build-1041
git push -q origin build-1041 2>/dev/null
git tag -d build-1041 >/dev/null
deploy
check "reads a tag from origin when the checkout has none" "$(body .build)" '"1041"'
deploy VIPER_BUILD_TAG='release-*'
check "takes another tag pattern" "$(body .build)" '"412"'
deploy VIPER_BUILD=2026.10.26
check "takes the build input over all of them" "$(body .build)" '"2026.10.26"'

echo "== Platforms and who deployed"
deploy VIPER_PLATFORMS="iOS, android"
check "lists the platforms" "$(body .platforms)" '["android","ios"]'
deploy VIPER_PLATFORMS="desktop"
check "refuses one it doesn't know" "$status" 1
deploy VIPER_DEPLOYED_BY="Sam Ortiz"
check "says who deployed" "$(body .deployed_by)" '"Sam Ortiz"'
check "writes the step's outputs" "$(grep -c '^deploy-id=deploy-1$' "$STATE/output")" 1

echo "== A long range"
new_repo
latest "$(git rev-parse HEAD)"
c "Merge pull request #1 from twinsunllc/SETCO-1-oldest"
parent=$(git rev-parse HEAD)
tree=$(git rev-parse 'HEAD^{tree}')
for n in $(seq 600); do parent=$(echo "Chore $n" | git commit-tree "$tree" -p "$parent"); done
git update-ref refs/heads/main "$parent"
c "Newest (#2)"
deploy
check "sends only the newest 500 commits" "$(body '.commit_shas | length')" 500
check "the newest one last" "$(body '.commit_shas[-1]')" "\"$(git rev-parse HEAD)\""
check "PRs from the whole range" "$(prs)" "[1,2]"
check "keys from the whole range" "$(body .jira_keys)" '["SETCO-1"]'

echo
echo "$passes passed, $failures failed"
[[ $failures -eq 0 ]]
