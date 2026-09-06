import assert from "node:assert/strict";
import {
  buildCountForMode,
  computePlayerIdentity,
  createArtifactEvidence,
  createBuildPlan,
  createDependencyEvidence,
  createDistributionReceipt,
  decideDependencyCache,
  dependencyCacheRelativePath,
  parseArtifactEvidence,
  parseDependencyEvidence,
  parseDistributionReceipt,
  playerRelativePath,
  serializeArtifactEvidence,
  serializeDependencyEvidence,
  serializeDistributionReceipt,
  validateReusableArtifact,
} from "./lan-distribution-contract.mjs";

const commit = "1".repeat(40);
const otherCommit = "9".repeat(40);
const tree = "2".repeat(40);
const lock = "3".repeat(64);
const digest = "4".repeat(64);
const node = "v22.14.0";
const npm = "10.9.2";
const identity = computePlayerIdentity(tree, lock);
const relativePath = playerRelativePath(identity);

assert.match(identity, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(computePlayerIdentity("5".repeat(40), lock), identity);
assert.notEqual(computePlayerIdentity(tree, "6".repeat(64)), identity);
assert.match(relativePath, /^players\/sha256-[0-9a-f]{64}$/);
assert.equal(playerRelativePath(computePlayerIdentity(tree, lock)), relativePath);
assert.equal(buildCountForMode("node"), 1);
assert.equal(buildCountForMode("integration"), 2);
assert.deepEqual(createBuildPlan("node"), [{ checkout: "checkout-1", package: "package-1" }]);
assert.deepEqual(createBuildPlan("integration"), [
  { checkout: "checkout-1", package: "package-1" },
  { checkout: "checkout-2", package: "package-2" },
]);
assert.throws(() => buildCountForMode("other"));

const dependency = createDependencyEvidence({
  package_lock_sha256: lock,
  node_version: node,
  npm_version: npm,
  platform: "win32",
  architecture: "x64",
  snapshot_relative_path: dependencyCacheRelativePath(lock, node, npm, "win32", "x64"),
  inventory_files: 123,
  total_bytes: 4567,
  inventory_sha256: digest,
});
assert.deepEqual(parseDependencyEvidence(serializeDependencyEvidence(dependency)), dependency);
assert.equal(decideDependencyCache(null, {
  package_lock_sha256: lock, node_version: node, npm_version: npm,
  platform: "win32", architecture: "x64",
}, false).status, "snapshot-created");
assert.equal(decideDependencyCache(dependency, {
  package_lock_sha256: lock, node_version: node, npm_version: npm,
  platform: "win32", architecture: "x64",
}, false).status, "snapshot-reused-verified");
assert.throws(() => decideDependencyCache(dependency, {
  package_lock_sha256: "7".repeat(64), node_version: node, npm_version: npm,
  platform: "win32", architecture: "x64",
}, false));
assert.throws(() => decideDependencyCache(dependency, {
  package_lock_sha256: lock, node_version: node, npm_version: npm,
  platform: "linux", architecture: "x64",
}, true));
assert.throws(() => decideDependencyCache(dependency, {
  package_lock_sha256: lock, node_version: "v22.15.0", npm_version: npm,
  platform: "win32", architecture: "x64",
}, false));
for (const invalid of [
  `${serializeDependencyEvidence(dependency).trim()} `,
  `${JSON.stringify({ ...dependency, unexpected: true })}\n`,
  `${JSON.stringify({ ...dependency, node_version: "v22" })}\n`,
  `${JSON.stringify({ ...dependency, snapshot_relative_path: "dependency-snapshots/elsewhere" })}\n`,
  `${JSON.stringify({ ...dependency, platform: "freebsd" })}\n`,
]) assert.throws(() => parseDependencyEvidence(invalid));

function artifact(created_build_mode = "integration") {
  return createArtifactEvidence({
    player_identity: identity,
    player_version: "0.1.0",
    config_schema_version: 1,
    source_tree: tree,
    package_lock_sha256: lock,
    node_version: node,
    npm_version: npm,
    platform: "win32",
    architecture: "x64",
    created_build_mode,
    created_builds: created_build_mode === "integration" ? 2 : 1,
    build_verification: created_build_mode === "integration"
      ? "double-build-byte-identical" : "single-build",
    manifest_sha256: digest,
    launcher_contract_sha256: digest,
    artifact_inventory_sha256: digest,
    player_relative_path: relativePath,
  });
}
const integrationArtifact = artifact();
assert.deepEqual(parseArtifactEvidence(serializeArtifactEvidence(integrationArtifact)), integrationArtifact);
validateReusableArtifact(integrationArtifact, integrationArtifact, "integration");
validateReusableArtifact(integrationArtifact, integrationArtifact, "node");
const nodeArtifact = artifact("node");
validateReusableArtifact(nodeArtifact, nodeArtifact, "node");
assert.throws(() => validateReusableArtifact(nodeArtifact, nodeArtifact, "integration"));
assert.throws(() => parseArtifactEvidence(`${JSON.stringify({ ...integrationArtifact, extra: 1 })}\n`));

function receipt(status, build_mode) {
  const reused = status === "reused";
  return createDistributionReceipt({
    status,
    updater_version: "2.0.0",
    build_mode,
    player_identity: identity,
    player_version: "0.1.0",
    config_schema_version: 1,
    source_commit: commit,
    source_tree: tree,
    package_lock_sha256: lock,
    node_version: node,
    npm_version: npm,
    platform: "win32",
    architecture: "x64",
    dependency_status: reused ? "not-used"
      : (build_mode === "integration" ? "integration-npm-ci" : "snapshot-reused-verified"),
    previous_source_commit: "none",
    source_diff_files: 0,
    source_diff_sha256: reused
      ? "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      : digest,
    builds_executed: reused ? 0 : buildCountForMode(build_mode),
    build_verification: reused
      ? (build_mode === "integration" ? "reused-integration-double" : "reused-node-single")
      : (build_mode === "integration" ? "double-build-byte-identical" : "single-build"),
    manifest_sha256: digest,
    launcher_contract_sha256: digest,
    artifact_inventory_sha256: digest,
    player_relative_path: relativePath,
  });
}
for (const value of [
  receipt("built", "node"), receipt("built", "integration"),
  receipt("reused", "node"), receipt("reused", "integration"),
]) assert.deepEqual(parseDistributionReceipt(serializeDistributionReceipt(value)), value);
const crossCommitReuse = createDistributionReceipt({
  ...receipt("reused", "node"), source_commit: otherCommit,
  previous_source_commit: commit,
});
const originalCommitReuse = receipt("reused", "node");
assert.equal(crossCommitReuse.status, "reused");
assert.equal(crossCommitReuse.builds_executed, 0);
assert.equal(crossCommitReuse.player_relative_path, relativePath);
assert.notEqual(crossCommitReuse.source_commit, originalCommitReuse.source_commit);
assert.equal(crossCommitReuse.player_identity, originalCommitReuse.player_identity);
assert.equal(crossCommitReuse.player_relative_path, originalCommitReuse.player_relative_path);
for (const invalid of [
  `${JSON.stringify({ ...receipt("built", "node"), builds_executed: 2 })}\n`,
  `${JSON.stringify({ ...receipt("built", "node"), dependency_status: "not-used" })}\n`,
  `${JSON.stringify({ ...receipt("reused", "integration"), build_verification: "reused-node-single" })}\n`,
  `${JSON.stringify({ ...receipt("reused", "node"), source_diff_files: -1 })}\n`,
  `${JSON.stringify({ ...receipt("built", "node"), secret: "forbidden" })}\n`,
  JSON.stringify(receipt("built", "node")),
]) assert.throws(() => parseDistributionReceipt(invalid));

console.log("lan-distribution-contract-test: PASS");
