#!/usr/bin/env bash
set -Eeuo pipefail

readonly EXIT_PREREQUISITE=10
readonly EXIT_AUTHENTICATION=11
readonly EXIT_REPOSITORY=20
readonly EXIT_REF_ABSENT=30
readonly EXIT_SHA_MISMATCH=40
readonly EXIT_TREE_MISMATCH=41
readonly EXIT_PROVENANCE=50
readonly EXIT_LICENSE=51
readonly EXIT_CONTROLS=60

readonly EXPECTED_UPSTREAM_URL=https://github.com/cloudflare/moq-rs.git
readonly EXPECTED_UPSTREAM_REPO=cloudflare/moq-rs
readonly EXPECTED_DERIVATIVE_REPO=Teremoq/moq-rs-teremoq

usage() {
  cat <<'USAGE'
Usage: verify-public-moq-derivative.sh [--config FILE] [--fixture-dir DIR]
       verify-public-moq-derivative.sh --allow-missing-integration-ref
       verify-public-moq-derivative.sh --help

Read-only, fail-closed verification of the controlled public moq-rs derivative.
The default configuration is gateway-rs/upstream/mirror/baseline.env. Live mode
uses authenticated GitHub REST reads without displaying credentials. It requires
the exact public independent repository, immutable approved ref/SHA/tree inventory,
preserved upstream license objects, and the mandatory GitHub controls.

--allow-missing-integration-ref is a one-way publication-transition check. It
requires the exact baseline-only inventory and tolerates only the configured
integration ref being absent. It never permits a mismatched or extra ref.

--fixture-dir is test-only. It reads scalar fixture files instead of GitHub and
prints mode=fixture, so its success is never evidence of remote state.

Exit codes:
  0   verification passed
  10  prerequisite or strict configuration failure
  11  GitHub authentication failure
  20  repository identity, visibility, independence, or archive failure
  30  baseline ref absent
  40  baseline ref SHA mismatch
  41  baseline tree mismatch
  50  upstream provenance or remote-ref inventory failure
  51  license/REUSE preservation failure
  60  mandatory GitHub control failure
USAGE
}

fail() {
  local code=$1
  local message=$2
  printf 'derivative verification failed: %s\n' "$message" >&2
  exit "$code"
}

script_path=${BASH_SOURCE[0]}
if [[ $script_path != */* ]]; then
  script_path=$(command -v -- "$script_path") ||
    fail "$EXIT_PREREQUISITE" "cannot resolve verifier location"
fi
script_dir=$(cd -- "${script_path%/*}" && pwd -P)
config_file="$script_dir/../../gateway-rs/upstream/mirror/baseline.env"
fixture_dir=
allow_missing_integration_ref=false

while (($# > 0)); do
  case $1 in
    --config)
      (($# >= 2)) || fail "$EXIT_PREREQUISITE" "--config requires a file"
      config_file=$2
      shift 2
      ;;
    --fixture-dir)
      (($# >= 2)) || fail "$EXIT_PREREQUISITE" "--fixture-dir requires a directory"
      fixture_dir=$2
      shift 2
      ;;
    --allow-missing-integration-ref)
      allow_missing_integration_ref=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "$EXIT_PREREQUISITE" "unknown argument"
      ;;
  esac
done

[[ -r $config_file && -f $config_file && ! -L $config_file ]] ||
  fail "$EXIT_PREREQUISITE" "configuration file is unavailable or unsafe"

declare -A config=()
declare -A seen=()
line_number=0
while IFS= read -r line || [[ -n $line ]]; do
  ((line_number += 1))
  [[ -n $line ]] || continue
  [[ $line != *$'\r'* ]] ||
    fail "$EXIT_PREREQUISITE" "configuration contains carriage returns"
  [[ $line =~ ^([A-Z0-9_]+)=([^[:space:]]+)$ ]] ||
    fail "$EXIT_PREREQUISITE" "invalid configuration syntax at line $line_number"
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  case $key in
    MOQ_UPSTREAM_URL|MOQ_MIRROR_REPO|MOQ_BASE_REV|MOQ_BASE_BRANCH|MOQ_BASE_TREE|MOQ_INTEGRATION_REV|MOQ_INTEGRATION_BRANCH|MOQ_INTEGRATION_TREE|MOQ_APACHE_LICENSE_BLOB|MOQ_MIT_LICENSE_BLOB|MOQ_REUSE_BLOB) ;;
    *) fail "$EXIT_PREREQUISITE" "unknown configuration key" ;;
  esac
  [[ ${seen[$key]+set} != set ]] ||
    fail "$EXIT_PREREQUISITE" "duplicate configuration key"
  seen[$key]=1
  config[$key]=$value
done <"$config_file"

for key in MOQ_UPSTREAM_URL MOQ_MIRROR_REPO MOQ_BASE_REV MOQ_BASE_BRANCH \
  MOQ_BASE_TREE MOQ_INTEGRATION_REV MOQ_INTEGRATION_BRANCH MOQ_INTEGRATION_TREE \
  MOQ_APACHE_LICENSE_BLOB MOQ_MIT_LICENSE_BLOB MOQ_REUSE_BLOB; do
  [[ ${seen[$key]+set} == set ]] ||
    fail "$EXIT_PREREQUISITE" "required configuration key is absent"
done

readonly MOQ_UPSTREAM_URL=${config[MOQ_UPSTREAM_URL]}
readonly MOQ_MIRROR_REPO=${config[MOQ_MIRROR_REPO]}
readonly MOQ_BASE_REV=${config[MOQ_BASE_REV]}
readonly MOQ_BASE_BRANCH=${config[MOQ_BASE_BRANCH]}
readonly MOQ_BASE_TREE=${config[MOQ_BASE_TREE]}
readonly MOQ_INTEGRATION_REV=${config[MOQ_INTEGRATION_REV]}
readonly MOQ_INTEGRATION_BRANCH=${config[MOQ_INTEGRATION_BRANCH]}
readonly MOQ_INTEGRATION_TREE=${config[MOQ_INTEGRATION_TREE]}
readonly MOQ_APACHE_LICENSE_BLOB=${config[MOQ_APACHE_LICENSE_BLOB]}
readonly MOQ_MIT_LICENSE_BLOB=${config[MOQ_MIT_LICENSE_BLOB]}
readonly MOQ_REUSE_BLOB=${config[MOQ_REUSE_BLOB]}

[[ $MOQ_UPSTREAM_URL == "$EXPECTED_UPSTREAM_URL" ]] ||
  fail "$EXIT_PREREQUISITE" "unexpected upstream URL"
[[ $MOQ_MIRROR_REPO == "$EXPECTED_DERIVATIVE_REPO" ]] ||
  fail "$EXIT_PREREQUISITE" "unexpected derivative repository"
[[ $MOQ_BASE_REV =~ ^[0-9a-f]{40}$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid baseline commit"
[[ $MOQ_BASE_TREE =~ ^[0-9a-f]{40}$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid baseline tree"
[[ $MOQ_INTEGRATION_REV =~ ^[0-9a-f]{40}$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid integration commit"
[[ $MOQ_INTEGRATION_TREE =~ ^[0-9a-f]{40}$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid integration tree"
[[ $MOQ_APACHE_LICENSE_BLOB =~ ^[0-9a-f]{40}$ && $MOQ_MIT_LICENSE_BLOB =~ ^[0-9a-f]{40}$ && $MOQ_REUSE_BLOB =~ ^[0-9a-f]{40}$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid license provenance object"
[[ $MOQ_BASE_BRANCH =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid baseline branch"
[[ $MOQ_INTEGRATION_BRANCH =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
  fail "$EXIT_PREREQUISITE" "invalid integration branch"
[[ $MOQ_BASE_BRANCH != */ && $MOQ_BASE_BRANCH != *..* && $MOQ_BASE_BRANCH != *//* ]] ||
  fail "$EXIT_PREREQUISITE" "unsafe baseline branch"
[[ $MOQ_INTEGRATION_BRANCH != */ && $MOQ_INTEGRATION_BRANCH != *..* && $MOQ_INTEGRATION_BRANCH != *//* ]] ||
  fail "$EXIT_PREREQUISITE" "unsafe integration branch"
[[ $MOQ_INTEGRATION_BRANCH != "$MOQ_BASE_BRANCH" ]] ||
  fail "$EXIT_PREREQUISITE" "approved branches must be distinct"

mode=live
if [[ -n $fixture_dir ]]; then
  mode=fixture
  [[ -d $fixture_dir && ! -L $fixture_dir ]] ||
    fail "$EXIT_PREREQUISITE" "fixture directory is unavailable or unsafe"
else
  command -v gh >/dev/null 2>&1 ||
    fail "$EXIT_PREREQUISITE" "required tool is unavailable"
  gh auth status >/dev/null 2>&1 ||
    fail "$EXIT_AUTHENTICATION" "GitHub authentication is unavailable"
fi

fixture_value() {
  local name=$1
  local path="$fixture_dir/$name"
  local -a lines=()
  [[ -f $path && ! -L $path ]] || return 1
  mapfile -t lines <"$path"
  ((${#lines[@]} == 1)) || return 1
  [[ -n ${lines[0]} && ${lines[0]} != *$'\r'* ]] || return 1
  printf '%s\n' "${lines[0]}"
}

live_value() {
  local name=$1
  case $name in
    repo_full_name) gh api "repos/$MOQ_MIRROR_REPO" --jq '.full_name' 2>/dev/null ;;
    visibility) gh api "repos/$MOQ_MIRROR_REPO" --jq '.visibility' 2>/dev/null ;;
    fork) gh api "repos/$MOQ_MIRROR_REPO" --jq '.fork' 2>/dev/null ;;
    parent) gh api "repos/$MOQ_MIRROR_REPO" --jq '.parent | if . == null then "null" else .full_name end' 2>/dev/null ;;
    archived) gh api "repos/$MOQ_MIRROR_REPO" --jq '.archived' 2>/dev/null ;;
    default_branch) gh api "repos/$MOQ_MIRROR_REPO" --jq '.default_branch' 2>/dev/null ;;
    secret_scanning) gh api "repos/$MOQ_MIRROR_REPO" --jq '.security_and_analysis.secret_scanning.status' 2>/dev/null ;;
    push_protection) gh api "repos/$MOQ_MIRROR_REPO" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null ;;
    web_signoff) gh api "repos/$MOQ_MIRROR_REPO" --jq '.web_commit_signoff_required' 2>/dev/null ;;
    ref_sha) gh api "repos/$MOQ_MIRROR_REPO/git/ref/heads/$MOQ_BASE_BRANCH" --jq '.object.sha' 2>/dev/null ;;
    integration_ref_sha) gh api "repos/$MOQ_MIRROR_REPO/git/ref/heads/$MOQ_INTEGRATION_BRANCH" --jq '.object.sha' 2>/dev/null ;;
    mirror_tree) gh api "repos/$MOQ_MIRROR_REPO/git/commits/$MOQ_BASE_REV" --jq '.tree.sha' 2>/dev/null ;;
    integration_tree) gh api "repos/$MOQ_MIRROR_REPO/git/commits/$MOQ_INTEGRATION_REV" --jq '.tree.sha' 2>/dev/null ;;
    upstream_sha) gh api "repos/$EXPECTED_UPSTREAM_REPO/git/commits/$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    upstream_tree) gh api "repos/$EXPECTED_UPSTREAM_REPO/git/commits/$MOQ_BASE_REV" --jq '.tree.sha' 2>/dev/null ;;
    branch_count) gh api "repos/$MOQ_MIRROR_REPO/git/matching-refs/heads" --jq 'length' 2>/dev/null ;;
    tag_count) gh api "repos/$MOQ_MIRROR_REPO/git/matching-refs/tags" --jq 'length' 2>/dev/null ;;
    upstream_apache_blob) gh api "repos/$EXPECTED_UPSTREAM_REPO/contents/LICENSES/Apache-2.0.txt?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    mirror_apache_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/LICENSES/Apache-2.0.txt?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    upstream_mit_blob) gh api "repos/$EXPECTED_UPSTREAM_REPO/contents/LICENSES/MIT.txt?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    mirror_mit_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/LICENSES/MIT.txt?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    upstream_reuse_blob) gh api "repos/$EXPECTED_UPSTREAM_REPO/contents/REUSE.toml?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    mirror_reuse_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/REUSE.toml?ref=$MOQ_BASE_REV" --jq '.sha' 2>/dev/null ;;
    integration_apache_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/LICENSES/Apache-2.0.txt?ref=$MOQ_INTEGRATION_REV" --jq '.sha' 2>/dev/null ;;
    integration_mit_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/LICENSES/MIT.txt?ref=$MOQ_INTEGRATION_REV" --jq '.sha' 2>/dev/null ;;
    integration_reuse_blob) gh api "repos/$MOQ_MIRROR_REPO/contents/REUSE.toml?ref=$MOQ_INTEGRATION_REV" --jq '.sha' 2>/dev/null ;;
    private_vulnerability_reporting) gh api "repos/$MOQ_MIRROR_REPO/private-vulnerability-reporting" --jq '.enabled' 2>/dev/null ;;
    dependabot_alerts)
      if gh api "repos/$MOQ_MIRROR_REPO/vulnerability-alerts" --silent >/dev/null 2>&1; then printf 'enabled\n'; else return 1; fi
      ;;
    actions_enabled) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions" --jq '.enabled' 2>/dev/null ;;
    allowed_actions) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions" --jq '.allowed_actions' 2>/dev/null ;;
    sha_pinning_required) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions" --jq '.sha_pinning_required' 2>/dev/null ;;
    github_owned_allowed) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions/selected-actions" --jq '.github_owned_allowed' 2>/dev/null ;;
    verified_allowed) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions/selected-actions" --jq '.verified_allowed' 2>/dev/null ;;
    patterns_count) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions/selected-actions" --jq '.patterns_allowed | length' 2>/dev/null ;;
    default_workflow_permissions) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null ;;
    can_approve_pull_request_reviews) gh api "repos/$MOQ_MIRROR_REPO/actions/permissions/workflow" --jq '.can_approve_pull_request_reviews' 2>/dev/null ;;
    *) return 1 ;;
  esac
}

get_value() {
  local name=$1
  if [[ $mode == fixture ]]; then
    fixture_value "$name"
  else
    live_value "$name"
  fi
}

repo_full_name=$(get_value repo_full_name) || fail "$EXIT_REPOSITORY" "repository identity is unavailable"
visibility=$(get_value visibility) || fail "$EXIT_REPOSITORY" "repository visibility is unavailable"
is_fork=$(get_value fork) || fail "$EXIT_REPOSITORY" "repository fork state is unavailable"
parent=$(get_value parent) || fail "$EXIT_REPOSITORY" "repository parent state is unavailable"
archived=$(get_value archived) || fail "$EXIT_REPOSITORY" "repository archive state is unavailable"
default_branch=$(get_value default_branch) || fail "$EXIT_REPOSITORY" "default branch is unavailable"

[[ $repo_full_name == "$EXPECTED_DERIVATIVE_REPO" && $visibility == public && $is_fork == false && $parent == null && $archived == false ]] ||
  fail "$EXIT_REPOSITORY" "repository is not the public independent active derivative"
[[ $default_branch == "$MOQ_BASE_BRANCH" ]] ||
  fail "$EXIT_PROVENANCE" "unexpected default branch"

remote_sha=$(get_value ref_sha) || fail "$EXIT_REF_ABSENT" "baseline ref is absent"
[[ $remote_sha == "$MOQ_BASE_REV" ]] ||
  fail "$EXIT_SHA_MISMATCH" "baseline ref does not match the approved commit"

integration_ref_present=true
integration_remote_sha=$(get_value integration_ref_sha) || integration_ref_present=false
if [[ $integration_ref_present == true ]]; then
  [[ $integration_remote_sha == "$MOQ_INTEGRATION_REV" ]] ||
    fail "$EXIT_SHA_MISMATCH" "integration ref does not match the approved commit"
elif [[ $allow_missing_integration_ref != true ]]; then
  fail "$EXIT_REF_ABSENT" "integration ref is absent"
fi

upstream_sha=$(get_value upstream_sha) || fail "$EXIT_PROVENANCE" "approved commit is absent from official upstream"
[[ $upstream_sha == "$MOQ_BASE_REV" ]] ||
  fail "$EXIT_PROVENANCE" "official upstream returned an unexpected commit"
upstream_tree=$(get_value upstream_tree) || fail "$EXIT_PROVENANCE" "official upstream tree is unavailable"
mirror_tree=$(get_value mirror_tree) || fail "$EXIT_TREE_MISMATCH" "derivative baseline tree is unavailable"
[[ $upstream_tree == "$MOQ_BASE_TREE" && $mirror_tree == "$MOQ_BASE_TREE" ]] ||
  fail "$EXIT_TREE_MISMATCH" "baseline tree differs from approved upstream tree"

branch_count=$(get_value branch_count) || fail "$EXIT_PROVENANCE" "branch inventory is unavailable"
tag_count=$(get_value tag_count) || fail "$EXIT_PROVENANCE" "tag inventory is unavailable"
if [[ $integration_ref_present == true ]]; then
  [[ $branch_count == 2 && $tag_count == 0 ]] ||
    fail "$EXIT_PROVENANCE" "unexpected branch or tag ref exists"
else
  [[ $branch_count == 1 && $tag_count == 0 ]] ||
    fail "$EXIT_PROVENANCE" "unexpected pre-publication branch or tag ref exists"
fi

upstream_apache_blob=$(get_value upstream_apache_blob) || fail "$EXIT_LICENSE" "upstream Apache license object is unavailable"
mirror_apache_blob=$(get_value mirror_apache_blob) || fail "$EXIT_LICENSE" "derivative Apache license object is unavailable"
upstream_mit_blob=$(get_value upstream_mit_blob) || fail "$EXIT_LICENSE" "upstream MIT license object is unavailable"
mirror_mit_blob=$(get_value mirror_mit_blob) || fail "$EXIT_LICENSE" "derivative MIT license object is unavailable"
upstream_reuse_blob=$(get_value upstream_reuse_blob) || fail "$EXIT_LICENSE" "upstream REUSE object is unavailable"
mirror_reuse_blob=$(get_value mirror_reuse_blob) || fail "$EXIT_LICENSE" "derivative REUSE object is unavailable"
[[ $upstream_apache_blob == "$MOQ_APACHE_LICENSE_BLOB" && $mirror_apache_blob == "$MOQ_APACHE_LICENSE_BLOB" && $upstream_mit_blob == "$MOQ_MIT_LICENSE_BLOB" && $mirror_mit_blob == "$MOQ_MIT_LICENSE_BLOB" && $upstream_reuse_blob == "$MOQ_REUSE_BLOB" && $mirror_reuse_blob == "$MOQ_REUSE_BLOB" ]] ||
  fail "$EXIT_LICENSE" "upstream license or REUSE provenance differs"

if [[ $integration_ref_present == true ]]; then
  integration_tree=$(get_value integration_tree) || fail "$EXIT_TREE_MISMATCH" "integration tree is unavailable"
  [[ $integration_tree == "$MOQ_INTEGRATION_TREE" ]] ||
    fail "$EXIT_TREE_MISMATCH" "integration tree differs from the approved tree"
  integration_apache_blob=$(get_value integration_apache_blob) || fail "$EXIT_LICENSE" "integration Apache license object is unavailable"
  integration_mit_blob=$(get_value integration_mit_blob) || fail "$EXIT_LICENSE" "integration MIT license object is unavailable"
  integration_reuse_blob=$(get_value integration_reuse_blob) || fail "$EXIT_LICENSE" "integration REUSE object is unavailable"
  [[ $integration_apache_blob == "$MOQ_APACHE_LICENSE_BLOB" && $integration_mit_blob == "$MOQ_MIT_LICENSE_BLOB" && $integration_reuse_blob == "$MOQ_REUSE_BLOB" ]] ||
    fail "$EXIT_LICENSE" "integration license or REUSE provenance differs"
fi

secret_scanning=$(get_value secret_scanning) || fail "$EXIT_CONTROLS" "Secret Scanning state is unavailable"
push_protection=$(get_value push_protection) || fail "$EXIT_CONTROLS" "Push Protection state is unavailable"
private_vulnerability_reporting=$(get_value private_vulnerability_reporting) || fail "$EXIT_CONTROLS" "Private Vulnerability Reporting state is unavailable"
dependabot_alerts=$(get_value dependabot_alerts) || fail "$EXIT_CONTROLS" "Dependabot Alerts state is unavailable"
actions_enabled=$(get_value actions_enabled) || fail "$EXIT_CONTROLS" "Actions state is unavailable"
allowed_actions=$(get_value allowed_actions) || fail "$EXIT_CONTROLS" "Actions policy is unavailable"
sha_pinning_required=$(get_value sha_pinning_required) || fail "$EXIT_CONTROLS" "Action SHA pinning state is unavailable"
github_owned_allowed=$(get_value github_owned_allowed) || fail "$EXIT_CONTROLS" "GitHub-owned Actions state is unavailable"
verified_allowed=$(get_value verified_allowed) || fail "$EXIT_CONTROLS" "verified Actions state is unavailable"
patterns_count=$(get_value patterns_count) || fail "$EXIT_CONTROLS" "Action patterns state is unavailable"
default_workflow_permissions=$(get_value default_workflow_permissions) || fail "$EXIT_CONTROLS" "workflow token permission is unavailable"
can_approve_pull_request_reviews=$(get_value can_approve_pull_request_reviews) || fail "$EXIT_CONTROLS" "workflow PR approval state is unavailable"
web_signoff=$(get_value web_signoff) || fail "$EXIT_CONTROLS" "web sign-off state is unavailable"

[[ $secret_scanning == enabled && $push_protection == enabled && $private_vulnerability_reporting == true && $dependabot_alerts == enabled && $actions_enabled == true && $allowed_actions == selected && $sha_pinning_required == true && $github_owned_allowed == true && $verified_allowed == false && $patterns_count == 0 && $default_workflow_permissions == read && $can_approve_pull_request_reviews == false && $web_signoff == true ]] ||
  fail "$EXIT_CONTROLS" "one or more mandatory GitHub controls are not enabled"

printf 'derivative verification passed\n'
printf 'mode=%s\n' "$mode"
printf 'repository=%s\n' "$MOQ_MIRROR_REPO"
printf 'baseline_commit=%s\n' "$MOQ_BASE_REV"
printf 'baseline_tree=%s\n' "$mirror_tree"
if [[ $integration_ref_present == true ]]; then
  printf 'integration_commit=%s\n' "$MOQ_INTEGRATION_REV"
  printf 'integration_tree=%s\n' "$integration_tree"
else
  printf 'integration_ref=pending_authorized_publication\n'
fi
printf 'license=MIT OR Apache-2.0\n'
if [[ $mode == live ]]; then
  printf 'pending_rulesets=not_required_by_this_verifier\n'
  printf 'pending_codeql_rust=not_required_by_this_verifier\n'
  printf 'pending_dependency_graph_sbom=not_assumed_by_this_verifier\n'
fi
