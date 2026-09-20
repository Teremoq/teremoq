#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
script_dir=$(cd -- "${script_path%/*}" && pwd -P)
verifier="$script_dir/verify-public-moq-derivative.sh"
config="$script_dir/../../gateway-rs/upstream/mirror/baseline.env"
tmp_dir=$(mktemp -d /tmp/teremoq-public-verifier.XXXXXX)

cleanup() {
  if [[ -d $tmp_dir ]]; then
    find "$tmp_dir" -depth -delete
  fi
}
trap cleanup EXIT

write_fixture() {
  local directory=$1
  mkdir -p "$directory"
  printf '%s\n' Teremoq/moq-rs-teremoq >"$directory/repo_full_name"
  printf '%s\n' public >"$directory/visibility"
  printf '%s\n' false >"$directory/fork"
  printf '%s\n' null >"$directory/parent"
  printf '%s\n' false >"$directory/archived"
  printf '%s\n' teremoq/baseline-draft16-bf87128 >"$directory/default_branch"
  printf '%s\n' enabled >"$directory/secret_scanning"
  printf '%s\n' enabled >"$directory/push_protection"
  printf '%s\n' true >"$directory/web_signoff"
  printf '%s\n' bf87128affd316463e5dcc7599a45001f222b6de >"$directory/ref_sha"
  printf '%s\n' 4b50958c121edfa2d6778c0586b30a78ee3e6f83 >"$directory/integration_ref_sha"
  printf '%s\n' d76319009e815fb8923e21fc8319e17a0aaf8174 >"$directory/mirror_tree"
  printf '%s\n' c0668647d8d2d6836320bc9662fe8ae717192795 >"$directory/integration_tree"
  printf '%s\n' bf87128affd316463e5dcc7599a45001f222b6de >"$directory/upstream_sha"
  printf '%s\n' d76319009e815fb8923e21fc8319e17a0aaf8174 >"$directory/upstream_tree"
  printf '%s\n' 2 >"$directory/branch_count"
  printf '%s\n' 0 >"$directory/tag_count"
  printf '%s\n' 55b366195e45a27ba1681037db12a9efe3cb3e6f >"$directory/upstream_apache_blob"
  printf '%s\n' 55b366195e45a27ba1681037db12a9efe3cb3e6f >"$directory/mirror_apache_blob"
  printf '%s\n' a6443463f9756ac500af0f4b62ae276a096429b8 >"$directory/upstream_mit_blob"
  printf '%s\n' a6443463f9756ac500af0f4b62ae276a096429b8 >"$directory/mirror_mit_blob"
  printf '%s\n' 39f45dc398c58993c3eab21d62c89d39b8b6fcd6 >"$directory/upstream_reuse_blob"
  printf '%s\n' 39f45dc398c58993c3eab21d62c89d39b8b6fcd6 >"$directory/mirror_reuse_blob"
  printf '%s\n' 55b366195e45a27ba1681037db12a9efe3cb3e6f >"$directory/integration_apache_blob"
  printf '%s\n' a6443463f9756ac500af0f4b62ae276a096429b8 >"$directory/integration_mit_blob"
  printf '%s\n' 39f45dc398c58993c3eab21d62c89d39b8b6fcd6 >"$directory/integration_reuse_blob"
  printf '%s\n' true >"$directory/private_vulnerability_reporting"
  printf '%s\n' enabled >"$directory/dependabot_alerts"
  printf '%s\n' true >"$directory/actions_enabled"
  printf '%s\n' selected >"$directory/allowed_actions"
  printf '%s\n' true >"$directory/sha_pinning_required"
  printf '%s\n' true >"$directory/github_owned_allowed"
  printf '%s\n' false >"$directory/verified_allowed"
  printf '%s\n' 0 >"$directory/patterns_count"
  printf '%s\n' read >"$directory/default_workflow_permissions"
  printf '%s\n' false >"$directory/can_approve_pull_request_reviews"
}

expect_exit() {
  local expected=$1
  local label=$2
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ $actual != "$expected" ]]; then
    printf 'not ok: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$actual"
}

remote_snapshot() {
  gh api repos/Teremoq/moq-rs-teremoq --jq '[.full_name,.visibility,.fork,.archived,.default_branch,.web_commit_signoff_required,.security_and_analysis.secret_scanning.status,.security_and_analysis.secret_scanning_push_protection.status] | @tsv'
  gh api repos/Teremoq/moq-rs-teremoq/git/matching-refs/heads --jq '[.[] | [.ref,.object.sha]] | @json'
  gh api repos/Teremoq/moq-rs-teremoq/git/matching-refs/tags --jq '[.[] | [.ref,.object.sha]] | @json'
  gh api repos/Teremoq/moq-rs-teremoq/actions/permissions --jq '[.enabled,.allowed_actions,.sha_pinning_required] | @tsv'
  gh api repos/Teremoq/moq-rs-teremoq/actions/permissions/selected-actions --jq '[.github_owned_allowed,.verified_allowed,(.patterns_allowed|length)] | @tsv'
  gh api repos/Teremoq/moq-rs-teremoq/actions/permissions/workflow --jq '[.default_workflow_permissions,.can_approve_pull_request_reviews] | @tsv'
}

before=$(remote_snapshot)
"$verifier" --config "$config" --allow-missing-integration-ref

fixture="$tmp_dir/base"
write_fixture "$fixture"
"$verifier" --config "$config" --fixture-dir "$fixture" >/dev/null

pre_publication="$tmp_dir/pre-publication"
write_fixture "$pre_publication"
mv "$pre_publication/integration_ref_sha" "$pre_publication/integration_ref_sha.absent"
printf '%s\n' 1 >"$pre_publication/branch_count"
"$verifier" --config "$config" --fixture-dir "$pre_publication" --allow-missing-integration-ref >/dev/null
expect_exit 30 'integration ref required outside transition' "$verifier" --config "$config" --fixture-dir "$pre_publication"

wrong_repo="$tmp_dir/wrong-repo"
write_fixture "$wrong_repo"
printf '%s\n' cloudflare/moq-rs >"$wrong_repo/repo_full_name"
expect_exit 20 'incorrect/non-independent repository' "$verifier" --config "$config" --fixture-dir "$wrong_repo"

missing_ref="$tmp_dir/missing-ref"
write_fixture "$missing_ref"
mv "$missing_ref/ref_sha" "$missing_ref/ref_sha.absent"
expect_exit 30 'missing baseline ref' "$verifier" --config "$config" --fixture-dir "$missing_ref"

wrong_sha="$tmp_dir/wrong-sha"
write_fixture "$wrong_sha"
printf '%040d\n' 0 >"$wrong_sha/ref_sha"
expect_exit 40 'wrong baseline SHA' "$verifier" --config "$config" --fixture-dir "$wrong_sha"

wrong_integration_sha="$tmp_dir/wrong-integration-sha"
write_fixture "$wrong_integration_sha"
printf '%040d\n' 0 >"$wrong_integration_sha/integration_ref_sha"
expect_exit 40 'wrong integration SHA' "$verifier" --config "$config" --fixture-dir "$wrong_integration_sha"

wrong_tree="$tmp_dir/wrong-tree"
write_fixture "$wrong_tree"
printf '%040d\n' 0 >"$wrong_tree/mirror_tree"
expect_exit 41 'wrong baseline tree/provenance' "$verifier" --config "$config" --fixture-dir "$wrong_tree"

wrong_integration_tree="$tmp_dir/wrong-integration-tree"
write_fixture "$wrong_integration_tree"
printf '%040d\n' 0 >"$wrong_integration_tree/integration_tree"
expect_exit 41 'wrong integration tree/provenance' "$verifier" --config "$config" --fixture-dir "$wrong_integration_tree"

extra_branch="$tmp_dir/extra-branch"
write_fixture "$extra_branch"
printf '%s\n' 3 >"$extra_branch/branch_count"
expect_exit 50 'unapproved third branch rejected' "$verifier" --config "$config" --fixture-dir "$extra_branch"

missing_control="$tmp_dir/missing-control"
write_fixture "$missing_control"
printf '%s\n' disabled >"$missing_control/secret_scanning"
expect_exit 60 'mandatory GitHub control absent' "$verifier" --config "$config" --fixture-dir "$missing_control"

expect_exit 10 'required tool absent' env PATH=/no-such-path /bin/bash "$verifier" --config "$config"

unknown_config="$tmp_dir/unknown.env"
cp "$config" "$unknown_config"
printf '%s\n' MOQ_UNKNOWN_KEY=value >>"$unknown_config"
expect_exit 10 'unknown configuration key' "$verifier" --config "$unknown_config" --fixture-dir "$fixture"

duplicate_config="$tmp_dir/duplicate.env"
cp "$config" "$duplicate_config"
printf '%s\n' MOQ_BASE_REV=bf87128affd316463e5dcc7599a45001f222b6de >>"$duplicate_config"
expect_exit 10 'duplicate configuration key' "$verifier" --config "$duplicate_config" --fixture-dir "$fixture"

injection_config="$tmp_dir/injection.env"
while IFS= read -r config_line || [[ -n $config_line ]]; do
  if [[ $config_line == MOQ_BASE_REV=* ]]; then
    printf 'MOQ_BASE_REV=$%s\n' '(id)'
  else
    printf '%s\n' "$config_line"
  fi
done <"$config" >"$injection_config"
expect_exit 10 'configuration injection syntax' "$verifier" --config "$injection_config" --fixture-dir "$fixture"

after=$(remote_snapshot)
[[ $before == "$after" ]] || {
  printf 'not ok: remote state changed during read-only tests\n' >&2
  exit 1
}
printf 'ok: remote state unchanged\n'
