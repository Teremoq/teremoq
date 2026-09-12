import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync("scripts/teremoq-lan-platform.ps1", "utf8");
const canary = readFileSync("scripts/test-managed-launcher.ps1", "utf8");

describe("frontera managed-v2 (regresiones de estructura, no E2E)", () => {
  it("liga el slot activo a arbol/lock y separa commit exterior de player", () => {
    expect(source).toContain("control/active.json");
    expect(source).toContain('"u-$($Active.updater_commit)-p-$IdentityHex"');
    expect(source).toContain('"schema_version=1`nsource_tree=$($Active.source_tree)`npackage_lock_sha256=$($Active.package_lock_sha256)`n"');
    expect(source).toContain("$ResolvedVersionPath -cne (Join-Path $ExpectedVersionRoot 'VERSION.tsv')");
    expect(source).toContain("$ScriptRoot -cne $ExpectedPlayerRoot");
  });

  it("conserva config6 exterior y solo enriquece el runtime7 en memoria", () => {
    const keys = source.split("$ConfigKeys = @(")[1].split(")")[0];
    expect(keys.match(/"[a-z_0-9]+"/g)).toHaveLength(6);
    expect(keys).not.toContain("source_commit");
    expect(source).toContain("source_commit = $Version.updater_commit");
    expect(source).toContain("UTF8.GetByteCount($CanonicalConfig) -gt 512");
    expect(source).toContain('$Version.schema_version -cne "2"');
    expect(source).not.toContain("$Version.package_version");
  });

  it("valida hashes sobre los bytes del mismo descriptor retenido", () => {
    expect(source).toContain("Sha256 = Get-BytesHash $Bytes");
    expect(source).toContain("Assert-OpenedPath $Stream $Path");
    expect(source).toContain("[IO.FileShare]::Read");
    expect(source).toContain("$PinnedStreams.Add($Stream)");
    expect(source).toContain("$PinnedStream.Dispose()");
    expect(source.indexOf("$PinnedStreams.Clear()")).toBeGreaterThan(source.indexOf("switch ($Action)"));
    expect(source).not.toContain("Get-FileHash");
  });

  it("ValidateOnly termina antes de efectos y no compila ni arranca procesos", () => {
    const boundary = source.indexOf("if ($ValidateOnly) {");
    expect(boundary).toBeGreaterThan(source.indexOf("$ActualPaths.Count -ne $ManifestPaths.Count"));
    expect(boundary).toBeLessThan(source.indexOf("[System.IO.Directory]::CreateDirectory"));
    const checks = source.slice(0, boundary);
    expect(checks).not.toMatch(/\b(Start-Process|Get-Command|Invoke-WebRequest)\b/);
    expect(checks).not.toMatch(/^\s*Add-Type\b/m);
    expect(checks).not.toMatch(/\$env:[A-Z_]+\s*=(?!=)/);
    expect(checks).not.toContain("WriteAllText");
    expect(source).toContain("Assert-CanonicalPath $EvidenceDirectory -AllowMissing");
  });

  it("no amplia actions ni evidencia player/carga", () => {
    expect(source).toContain('[ValidateSet("start", "status", "stop", "collect")]');
    expect(source).toContain('$Package.actions -cne "start,status,stop,collect"');
    expect(source).toContain('$ValidateOnly -and $Action -ine "start"');
    expect(source).not.toContain("lan-real-player-baseline");
  });

  it("acota contratos, cardinalidad e inventario y rechaza duplicados", () => {
    expect(source).toContain("Convert-CanonicalJson");
    expect(source).toContain("$Result.ContainsKey($Parts[0])");
    expect(source).toContain("$Manifest.files.Count -gt 10000");
    expect(source).toContain("$EntryCount -gt 20000");
    expect(source).toContain("$Manifest.total_bytes -gt 128MB");
    expect(source).toContain("Read-BoundedDocument $ManifestPath 1048576");
  });

  it("canario usa productor Platform real y distingue fixture de build", () => {
    expect(canary).toContain("New-TeremoqLanSlotRecord -UpdaterCommit");
    expect(canary).toContain("ConvertTo-TeremoqLanSlotJson");
    expect(canary).toContain("offline-ps51-contract-fixtures-not-live-prepare");
    expect(canary).toContain("TEST FIXTURE MUST NEVER EXECUTE");
    expect(canary).toContain("validation mutated environment");
    expect(canary).toContain("validation mutated files");
  });
});
