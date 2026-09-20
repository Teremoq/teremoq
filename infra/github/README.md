# GitHub repository controls

This directory stores reviewable repository policy. Files in `rulesets/` use
GitHub's repository ruleset REST shape with `enforcement` set to `disabled`.
They are not active merely because they are versioned here.

## Safe activation order

1. Confirm at least two tested maintainer recovery paths and current repository
   administrator access.
2. Re-read the repository's default branch, existing rulesets, branch
   protection and workflow/check names through the API.
3. Create each ruleset in `disabled` state and inspect its evaluated targets.
4. For `v*`, validate the creation ruleset's maintainer/admin bypass with a
   disposable non-release tag while both tag rulesets remain disabled.
5. Activate the `v*` creation restriction first, verify authorized creation,
   and only then activate the independent no-bypass immutability ruleset. The
   latter blocks update, deletion and non-fast-forward operations even for an
   organization administrator until the ruleset itself is disabled.
6. Enable the `teremoq/baseline-*` protection only after validating recovery
   with a non-default test reference.
7. Establish the first stable CI run and record exact required-check names.
8. Add those checks to the `main` ruleset, then use `evaluate` if available.
9. Activate `main` last, verify that the sole maintainer can use the documented
   pull-request path, and retain an audited rollback procedure.

Do not activate all rulesets in one change. In particular, the current default
branch of `Teremoq/moq-rs-teremoq` matches the baseline pattern, so its baseline
ruleset must not be enabled before a safe default-branch and bypass plan exists.

The JSON files intentionally omit required status-check names. Adding guessed
names can permanently block merging when no workflow emits them.

There are four disabled rulesets per repository: baseline branches, `main`,
`v*` creation, and `v*` immutability. The creation bypass is deliberately not
present in the immutability ruleset.
