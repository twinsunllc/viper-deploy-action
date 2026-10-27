#!/usr/bin/env bash
# Reports a deploy to Viper (D354): asks Viper for the environment's last CI commit, walks the
# commits HEAD added since it and the ones it took away, and posts the deploy, signed with the
# environment's deploy token (D226).
#
# Written for bash 3.2 (macOS runners' /bin/bash) with git, jq, openssl, curl and od. The token
# only ever reaches builtins (printf, [[ ]]), never another program's arguments, so it can't show
# in a process list.
#
# Inputs, all from the environment:
#   VIPER_URL, VIPER_ENVIRONMENT_ID, VIPER_DEPLOY_TOKEN   required
#   VIPER_BUILD        the build's name; default the highest VIPER_BUILD_TAG tag at HEAD, else the run number
#   VIPER_BUILD_TAG    default "build-*"; "build-1041" names the build "1041"
#   VIPER_PLATFORMS    ios, android and web, separated by commas or spaces; empty is every platform
#   VIPER_DEPLOYED_BY  default GITHUB_ACTOR
#   VIPER_DRY_RUN      "true" prints the payload instead of posting it
#   GITHUB_*           what Actions sets: the run, the job, the repository, the ref
set -euo pipefail

MAX_COMMITS=500
JIRA_KEY='[A-Z][A-Z0-9_]+-[0-9]+'

fail() { echo "::error title=Viper deploy::$*" >&2; exit 1; }
warn() { echo "::warning title=Viper deploy::$*" >&2; }
note() { echo "$*" >&2; }

: "${VIPER_URL:?viper-url is required}"
: "${VIPER_ENVIRONMENT_ID:?environment-id is required}"
[[ -n "${VIPER_DEPLOY_TOKEN:-}" ]] || fail "token is empty. Pass the environment's deploy token from a secret: token: \${{ secrets.VIPER_DEPLOY_TOKEN }}"
for tool in git jq openssl curl od; do command -v "$tool" >/dev/null || fail "$tool is not installed on this runner"; done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "no git checkout here. Run actions/checkout before this action."

VIPER_URL="${VIPER_URL%/}"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/viper-deploy.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# --- HMAC-SHA256, with the key kept to builtins ------------------------------------------------

# Writes the 64-byte HMAC pad for the token, XORed with $1 (0x36 inner, 0x5c outer), to $2.
pad_key() {
  local xor=$1 out=$2 key_hex escaped='' i byte
  key_hex=$(printf '%s' "$VIPER_DEPLOY_TOKEN" | od -An -v -tx1 | tr -d ' \n')
  # A key longer than the block is hashed first (RFC 2104).
  if (( ${#key_hex} > 128 )); then
    key_hex=$(printf '%s' "$VIPER_DEPLOY_TOKEN" | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
  fi
  for (( i = 0; i < 64; i++ )); do
    byte=0
    (( i * 2 < ${#key_hex} )) && byte=$(( 16#${key_hex:i*2:2} ))
    escaped+=$(printf '\\x%02x' $(( byte ^ xor )))
  done
  # The format is the pad's own \xHH escapes, built above from numbers only.
  # shellcheck disable=SC2059
  printf "$escaped" > "$out"
}

# The hex HMAC-SHA256 of the file $1 with the token.
hmac_file() {
  local file=$1
  pad_key 0x36 "$WORK/ipad"
  pad_key 0x5c "$WORK/opad"
  cat "$WORK/ipad" "$file" | openssl dgst -sha256 -binary > "$WORK/inner"
  cat "$WORK/opad" "$WORK/inner" | openssl dgst -sha256 -r | cut -d' ' -f1
  rm -f "$WORK/ipad" "$WORK/opad" "$WORK/inner"
}

# Signs "<timestamp>.<message in file $1>", printing "<timestamp> <signature>".
sign() {
  local ts
  ts=$(date +%s)
  { printf '%s.' "$ts"; cat "$1"; } > "$WORK/signed"
  printf '%s %s\n' "$ts" "$(hmac_file "$WORK/signed")"
}

# --- What Viper already has --------------------------------------------------------------------

# The environment's last CI commit, or nothing on a first run (D354).
last_commit() {
  local path="/webhooks/deploys/$VIPER_ENVIRONMENT_ID/latest" ts sig status
  printf 'GET %s' "$path" > "$WORK/get"
  read -r ts sig < <(sign "$WORK/get")
  status=$(curl -sS -o "$WORK/latest.json" -w '%{http_code}' -H "X-Viper-Timestamp: $ts" -H "X-Viper-Signature: $sig" "$VIPER_URL$path") ||
    fail "couldn't reach $VIPER_URL"
  case "$status" in
    200) jq -r '.commit_sha // empty' "$WORK/latest.json" ;;
    401) fail "Viper refused the signature: $(jq -r '.error // empty' "$WORK/latest.json" 2>/dev/null). Check the token is this environment's deploy token." ;;
    404) fail "Viper has no environment $VIPER_ENVIRONMENT_ID at $VIPER_URL." ;;
    *) warn "Viper answered $status for the last commit, so this deploy goes without its range."; echo '' ;;
  esac
}

# Makes sure git can walk from $1 to HEAD: deepens a shallow clone and fetches a commit from
# another branch. Fails quietly; the caller checks.
have_commit() {
  local sha=$1
  git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  git remote get-url origin >/dev/null 2>&1 || return 1
  if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
    note "Fetching history (the checkout is shallow)."
    git fetch --quiet --no-tags --unshallow origin 2>/dev/null || git fetch --quiet --no-tags --depth=100000 origin 2>/dev/null || true
  fi
  git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  git fetch --quiet --no-tags origin "$sha" 2>/dev/null || true
  git cat-file -e "$sha^{commit}" 2>/dev/null
}

# --- Reading a range ---------------------------------------------------------------------------

# Every Jira key in $1, one per line.
keys_in() {
  local rest=$1
  while [[ $rest =~ ($JIRA_KEY) ]]; do
    echo "${BASH_REMATCH[1]}"
    rest=${rest#*"${BASH_REMATCH[1]}"}
  done
}

# "<add|remove>\tkey\t<key>" for every key in $2.
emit_keys() {
  local kind=$1 key
  keys_in "$2" | while IFS= read -r key; do printf '%s\tkey\t%s\n' "$kind" "$key"; done
}

# The branch part of "owner/branch".
branch_of() { echo "${1#*/}"; }

# For each commit in the range $1 (oldest first), what it does, as "<add|remove>\t<pr|key>\t<value>":
# - "Merge pull request #330 from owner/SETCO-921-x" adds #330 and the branch's keys;
# - "Title (#330)", a squash, adds #330 and the subject's keys;
# - a merged "revert-330-..." branch, "Revert \"Title (#330)\" (#340)" and a plain
#   "Revert \"...\"" take the reverted PR and its keys away, and add nothing.
# Keys only ever come from merged branch names and those merge and squash subjects.
events() {
  local subject inner branch pr
  git log --reverse --format='%s' "$1" | while IFS= read -r subject; do
    if [[ $subject =~ ^Revert\ \"(.*)\"( \(#[0-9]+\))?$ ]]; then
      inner=${BASH_REMATCH[1]}
      if [[ $inner =~ ^Merge\ pull\ request\ \#([0-9]+)\ from\ ([^ ]+) ]]; then
        printf 'remove\tpr\t%s\n' "${BASH_REMATCH[1]}"
        emit_keys remove "$(branch_of "${BASH_REMATCH[2]}")"
      elif [[ $inner =~ \(#([0-9]+)\)$ ]]; then
        printf 'remove\tpr\t%s\n' "${BASH_REMATCH[1]}"
        emit_keys remove "$inner"
      fi
    elif [[ $subject =~ ^Merge\ pull\ request\ \#([0-9]+)\ from\ ([^ ]+) ]]; then
      pr=${BASH_REMATCH[1]}
      branch=$(branch_of "${BASH_REMATCH[2]}")
      if [[ $branch =~ (^|/)revert-([0-9]+)- ]]; then
        printf 'remove\tpr\t%s\n' "${BASH_REMATCH[2]}"
        emit_keys remove "$branch"
      else
        printf 'add\tpr\t%s\n' "$pr"
        emit_keys add "$branch"
      fi
    elif [[ $subject =~ \(#([0-9]+)\)$ ]]; then
      printf 'add\tpr\t%s\n' "${BASH_REMATCH[1]}"
      emit_keys add "$subject"
    fi
  done
}

# The last word on each PR and key in a list of events: the later commit wins.
settle() {
  awk -F'\t' '{ state[$2 "\t" $3] = $1; order[$2 "\t" $3] = NR }
              END { for (k in state) print order[k] "\t" state[k] "\t" k }' | sort -n | cut -f2-
}

# --- The deploy --------------------------------------------------------------------------------

head_sha=$(git rev-parse HEAD)
repository=${GITHUB_REPOSITORY:-}
branch=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}
deployed_by=${VIPER_DEPLOYED_BY:-${GITHUB_ACTOR:-}}
run_url=''
[[ -n "${GITHUB_RUN_ID:-}" && -n "$repository" ]] && run_url="${GITHUB_SERVER_URL:-https://github.com}/$repository/actions/runs/$GITHUB_RUN_ID"

# The build's name: the input, else the highest matching tag at HEAD (local or on origin), else
# the run number.
build=${VIPER_BUILD:-}
if [[ -z "$build" ]]; then
  pattern=${VIPER_BUILD_TAG:-build-*}
  prefix=${pattern%%\**}
  # A checkout with no origin (a local run) has only its own tags; a remote that can't be
  # reached is never a reason to fail the deploy.
  tags=$( { git tag --points-at HEAD --list "$pattern" 2>/dev/null || true
            if git remote get-url origin >/dev/null 2>&1; then
              { git ls-remote --tags origin "refs/tags/$pattern" 2>/dev/null || true; } |
                awk -v head="$head_sha" '$1 == head { sub("^refs/tags/", "", $2); sub("\\^\\{\\}$", "", $2); print $2 }'
            fi
          } | sort -u)
  if [[ -n "$tags" ]]; then
    build=$(echo "$tags" | sed "s|^$prefix||" | sort -V | tail -1)
    note "Build $build, from the tag $prefix$build at HEAD."
  else
    build=${GITHUB_RUN_NUMBER:-}
    [[ -n "$build" ]] && note "Build $build, the run number (no $pattern tag at HEAD)."
  fi
fi

# Commas and spaces both become newlines.
# shellcheck disable=SC2020
platforms=$(echo "${VIPER_PLATFORMS:-}" | tr ', ' '\n\n' | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u)
for os in $platforms; do
  [[ $os == ios || $os == android || $os == web ]] || fail "platforms takes ios, android and web; got \"$os\""
done

last=$(last_commit)
range_known=false
: > "$WORK/added"; : > "$WORK/removed"
printf '%s\n' "$head_sha" > "$WORK/commits"
if [[ -z "$last" ]]; then
  note "Viper has no CI commit for this environment yet: sending HEAD only, with range_known false."
elif ! have_commit "$last"; then
  warn "git can't find the last deployed commit $last (a force-push, or another repository), so this deploy names no fixes."
else
  range_known=true
  events "$last..HEAD" | settle > "$WORK/added"
  events "HEAD..$last" | settle > "$WORK/removed"
  git rev-list --reverse "$last..HEAD" | tail -n "$MAX_COMMITS" > "$WORK/commits"
  note "Range $(git rev-parse --short "$last")..$(git rev-parse --short HEAD): $(wc -l < "$WORK/commits" | tr -d ' ') commits sent, $(git rev-list --count "HEAD..$last") taken away."
fi

# What HEAD gained, and what it lost: removed in the range, or added only in what it left behind.
list() { awk -F'\t' -v want="$1" -v kind="$2" '$1 == want && $2 == kind { print $3 }' "$3"; }
list add pr "$WORK/added" > "$WORK/prs"
list add key "$WORK/added" > "$WORK/keys"
{ list remove pr "$WORK/added"; list add pr "$WORK/removed"; } | grep -vxF -f "$WORK/prs" | awk '!seen[$0]++' > "$WORK/removed_prs" || true
{ list remove key "$WORK/added"; list add key "$WORK/removed"; } | grep -vxF -f "$WORK/keys" | awk '!seen[$0]++' > "$WORK/removed_keys" || true

to_json() { jq -R . < "$1" | jq -s .; }
prs_json() { jq -R --arg repo "$repository" '{repository: $repo, number: tonumber}' < "$1" | jq -s .; }

jq -n \
  --arg build "$build" --arg sha "$head_sha" --arg branch "$branch" --arg by "$deployed_by" \
  --arg repository "$repository" --arg run_url "$run_url" --argjson range_known "$range_known" \
  --argjson commits "$(to_json "$WORK/commits")" --argjson platforms "$(echo "$platforms" | sed '/^$/d' | jq -R . | jq -s .)" \
  --argjson prs "$(prs_json "$WORK/prs")" --argjson removed_prs "$(prs_json "$WORK/removed_prs")" \
  --argjson keys "$(to_json "$WORK/keys")" --argjson removed_keys "$(to_json "$WORK/removed_keys")" \
  '{build: $build, commit_sha: $sha, commit_shas: $commits, branch: $branch, deployed_by: $by,
    pull_requests: $prs, removed_pull_requests: $removed_prs, jira_keys: $keys, removed_jira_keys: $removed_keys,
    range_known: $range_known, platforms: $platforms, repository: $repository, run_url: $run_url}
   | with_entries(select(.value != "" and .value != null))' > "$WORK/body"
# jq writes a trailing newline; the signature covers exactly the bytes posted.
printf '%s' "$(cat "$WORK/body")" > "$WORK/body.json"

note "Pull requests added: $(jq -r '[.pull_requests[].number|"#\(.)"]|join(", ")|if .=="" then "none" else . end' "$WORK/body.json"); taken away: $(jq -r '[.removed_pull_requests[].number|"#\(.)"]|join(", ")|if .=="" then "none" else . end' "$WORK/body.json")."
note "Jira keys added: $(jq -r '.jira_keys|join(", ")|if .=="" then "none" else . end' "$WORK/body.json"); taken away: $(jq -r '.removed_jira_keys|join(", ")|if .=="" then "none" else . end' "$WORK/body.json")."

if [[ "${VIPER_DRY_RUN:-}" == true ]]; then
  cat "$WORK/body.json"; echo
  exit 0
fi

delivery="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-deploy}"
read -r ts sig < <(sign "$WORK/body.json")
status=$(curl -sS -o "$WORK/answer.json" -w '%{http_code}' -X POST "$VIPER_URL/webhooks/deploys/$VIPER_ENVIRONMENT_ID" \
  -H 'Content-Type: application/json' -H "X-Viper-Timestamp: $ts" -H "X-Viper-Delivery: $delivery" -H "X-Viper-Signature: $sig" \
  --data-binary "@$WORK/body.json") || fail "couldn't reach $VIPER_URL"
case "$status" in
  200|201) ;;
  *) fail "Viper answered $status: $(jq -r '.error // empty' "$WORK/answer.json" 2>/dev/null || cat "$WORK/answer.json")" ;;
esac

deploy_id=$(jq -r '.deploy_id // empty' "$WORK/answer.json")
outcome=$(jq -r '.outcome // empty' "$WORK/answer.json")
echo "Viper recorded build $(jq -r '.build' "$WORK/answer.json") ($outcome)."
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "deploy-id=$deploy_id"; echo "build=$(jq -r '.build' "$WORK/answer.json")"; echo "outcome=$outcome"; echo "range-known=$range_known"; } >> "$GITHUB_OUTPUT"
fi
