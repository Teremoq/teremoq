const LAN_LAB_CONFIG_MAX_BYTES = 512;
const LAN_LAB_RELAY_PORT = "14433";
const LAN_LAB_RELAY_PATH = "/watch";
const LAN_LAB_CONFIG_KEYS = [
  "fingerprint_sha256",
  "namespace",
  "prefix_length",
  "relay_url",
  "run_id",
  "schema_version",
  "source_commit",
] as const;

export const LAN_LOAD_SESSION_LEVELS = [5, 10, 25] as const;
export type LanLoadSessionLevel = (typeof LAN_LOAD_SESSION_LEVELS)[number];

export type LanLabConfiguration = Readonly<{
  schema_version: 1;
  relay_url: string;
  fingerprint_sha256: string;
  prefix_length: number;
  namespace: string;
  run_id: string;
  source_commit: string;
}>;

export type PlayerDeployment =
  | Readonly<{
      mode: "loopback";
      environmentLabel: "LAB LOOPBACK";
      configurationSource: "gateway-read-only";
      metricsStatus: "available";
      operationsAvailable: true;
    }>
  | Readonly<{
      mode: "lan-lab";
      environmentLabel: "LAN LAB / NO PRODUCCIÓN";
      configurationSource: "local-environment";
      configurationStatus: "available" | "unavailable";
      metricsStatus: "not_measured";
      operationsAvailable: false;
      configuration: LanLabConfiguration | null;
    }>;

type RuntimeEnvironment = Readonly<Record<string, string | undefined>>;

export function isLanLabEnabled(environment: RuntimeEnvironment) {
  return environment.TEREMOQ_LAN_LAB === "1";
}

export function configuredLanLoadLevel(
  environment: RuntimeEnvironment,
): LanLoadSessionLevel | null {
  const value = environment.TEREMOQ_LAN_LAB_LEVEL;
  if (value === undefined || value === "1") return null;
  if (value === "5") return 5;
  if (value === "10") return 10;
  if (value === "25") return 25;
  return null;
}

export function resolvePlayerDeployment(environment: RuntimeEnvironment): PlayerDeployment {
  if (!isLanLabEnabled(environment)) {
    return Object.freeze({
      mode: "loopback",
      environmentLabel: "LAB LOOPBACK",
      configurationSource: "gateway-read-only",
      metricsStatus: "available",
      operationsAvailable: true,
    });
  }

  try {
    const configuration = parseLanLabConfigurationJson(
      environment.TEREMOQ_LAN_LAB_CONFIG,
    );
    return Object.freeze({
      mode: "lan-lab",
      environmentLabel: "LAN LAB / NO PRODUCCIÓN",
      configurationSource: "local-environment",
      configurationStatus: "available",
      metricsStatus: "not_measured",
      operationsAvailable: false,
      configuration,
    });
  } catch {
    return Object.freeze({
      mode: "lan-lab",
      environmentLabel: "LAN LAB / NO PRODUCCIÓN",
      configurationSource: "local-environment",
      configurationStatus: "unavailable",
      metricsStatus: "not_measured",
      operationsAvailable: false,
      configuration: null,
    });
  }
}

export function parseLanLabConfigurationJson(raw: string | undefined) {
  if (!raw || new TextEncoder().encode(raw).byteLength > LAN_LAB_CONFIG_MAX_BYTES) {
    throw new Error("configuración LAN no disponible");
  }
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("configuración LAN inválida");
  }
  return parseLanLabConfiguration(value);
}

export function parseLanLabConfiguration(value: unknown): LanLabConfiguration {
  if (!isRecord(value) || !hasExactConfigurationKeys(value)) {
    throw new Error("contrato LAN inválido");
  }
  if (
    value.schema_version !== 1 ||
    typeof value.relay_url !== "string" ||
    typeof value.fingerprint_sha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(value.fingerprint_sha256) ||
    !Number.isInteger(value.prefix_length) ||
    typeof value.prefix_length !== "number" ||
    value.prefix_length < 8 ||
    value.prefix_length > 30 ||
    typeof value.namespace !== "string"
    || typeof value.run_id !== "string"
    || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value.run_id)
    || typeof value.source_commit !== "string"
    || !/^[0-9a-f]{40}$/.test(value.source_commit)
  ) {
    throw new Error("contrato LAN inválido");
  }

  const relayUrl = validateLanRelayUrl(value.relay_url, value.prefix_length);
  const namespace = validateMoqNamespace(value.namespace);
  return Object.freeze({
    schema_version: 1,
    relay_url: relayUrl,
    fingerprint_sha256: value.fingerprint_sha256,
    prefix_length: value.prefix_length,
    namespace,
    run_id: value.run_id,
    source_commit: value.source_commit,
  });
}

export function playerDataPolicy(deployment: PlayerDeployment) {
  const loopback = deployment.mode === "loopback";
  return Object.freeze({
    loadGatewayPlayback: loopback,
    pollGatewaySnapshot: loopback,
    loadInputPreview: loopback,
    operationsAvailable: loopback,
    missingMetricStatus: loopback ? "unavailable" : "not_measured",
  } as const);
}

export type LanLabRequestDecision =
  | "allow"
  | "misdirected"
  | "not-found"
  | "method-not-allowed";

export function lanLabRequestDecision(
  host: string | null,
  pathname: string,
  method: string,
): LanLabRequestDecision {
  if (!isLocalUiHost(host)) return "misdirected";
  if (method !== "GET" && method !== "HEAD") return "method-not-allowed";
  if (!isAllowedLanPath(pathname)) return "not-found";
  return "allow";
}

export function supervisorRewrites(environment: RuntimeEnvironment) {
  if (isLanLabEnabled(environment)) return [];
  const gatewayOrigin =
    environment.TEREMOQ_GATEWAY_HTTP_ORIGIN ?? "http://127.0.0.1:19080";
  const inputPreviewOrigin =
    environment.TEREMOQ_INPUT_PREVIEW_ORIGIN ?? "http://127.0.0.1:8889";
  return [
    { source: "/gateway/:path*", destination: `${gatewayOrigin}/:path*` },
    { source: "/input/", destination: `${inputPreviewOrigin}/input/` },
    {
      source: "/input/:path*",
      destination: `${inputPreviewOrigin}/input/:path*`,
    },
  ];
}

function validateLanRelayUrl(value: string, prefixLength: number) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("URL LAN inválida");
  }
  const address = parsePrivateIpv4(url.hostname);
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.port !== LAN_LAB_RELAY_PORT ||
    url.pathname !== LAN_LAB_RELAY_PATH ||
    url.search !== "" ||
    url.hash !== "" ||
    address === null ||
    url.toString() !== value
  ) {
    throw new Error("URL LAN fuera de contrato");
  }
  validatePrivateSubnetHost(address, prefixLength);
  return url.toString();
}

function validateMoqNamespace(value: string) {
  if (
    value.length === 0 ||
    new TextEncoder().encode(value).byteLength > 256 ||
    !/^[\x00-\x7f]+$/.test(value)
  ) {
    throw new Error("namespace MoQT inválido");
  }
  const segments = value.split("/");
  if (
    segments.some(
      (segment) =>
        segment === "" ||
        segment === "." ||
        segment === ".." ||
        !/^[A-Za-z0-9._-]+$/.test(segment),
    )
  ) {
    throw new Error("namespace MoQT inválido");
  }
  return value;
}

function parsePrivateIpv4(hostname: string): readonly number[] | null {
  if (!/^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$/.test(hostname)) {
    return null;
  }
  const octets = hostname.split(".").map(Number);
  if (octets.some((octet) => octet > 255)) return null;
  const privateAddress =
    octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
  return privateAddress ? octets : null;
}

function validatePrivateSubnetHost(octets: readonly number[], prefixLength: number) {
  const privateBlockPrefix = octets[0] === 10 ? 8 : octets[0] === 172 ? 12 : 16;
  if (prefixLength < privateBlockPrefix) {
    throw new Error("subred LAN fuera de RFC1918");
  }
  const address = octets.reduce((value, octet) => value * 256 + octet, 0) >>> 0;
  const mask = (0xffff_ffff << (32 - prefixLength)) >>> 0;
  const network = (address & mask) >>> 0;
  const broadcast = (network | (~mask >>> 0)) >>> 0;
  if (address === network || address === broadcast) {
    throw new Error("host LAN no utilizable");
  }
}

function isLocalUiHost(value: string | null) {
  if (value === null) return false;
  const match = /^(localhost|127\.0\.0\.1)(?::([1-9]\d{0,4}))?$/i.exec(value);
  if (!match) return false;
  if (match[2] === undefined) return true;
  return Number(match[2]) <= 65_535;
}

function isAllowedLanPath(pathname: string) {
  let normalized: string;
  try {
    normalized = decodeURIComponent(pathname).replaceAll("\\", "/").toLowerCase();
  } catch {
    return false;
  }
  if (normalized.startsWith("//")) return false;
  return normalized === "/" ||
    normalized === "/lan-load" ||
    normalized === "/favicon.ico" ||
    normalized.startsWith("/_next/");
}

function hasExactConfigurationKeys(value: Record<string, unknown>) {
  const keys = Object.keys(value).sort();
  return keys.length === LAN_LAB_CONFIG_KEYS.length &&
    keys.every((key, index) => key === LAN_LAB_CONFIG_KEYS[index]);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
