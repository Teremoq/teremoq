//! Routing validado entre fuentes MPEG-TS y Tracks lógicos.

use std::collections::HashSet;

use serde::Deserialize;

use crate::error::{GatewayError, GatewayResult};

const TRACK_COUNT: usize = 4;
const MAX_STREAM_ID_BYTES: usize = 512;
const MAX_SOURCE_LABEL_BYTES: usize = 64;
const MIN_ELEMENTARY_PID: u16 = 0x0020;
const MAX_ELEMENTARY_PID: u16 = 0x1FFE;

/// Identidad interna estable de los cuatro Tracks Teremoq.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u8)]
pub enum TrackId {
    /// Vídeo de máxima calidad.
    VideoHq = 0,
    /// Vídeo de fallback.
    VideoLq = 1,
    /// Audio crítico.
    CriticalAudio = 2,
    /// Telemetría JSON.
    Telemetry = 3,
}

impl TrackId {
    /// Devuelve el identificador numérico estable del Track.
    #[must_use]
    pub const fn value(self) -> u8 {
        self as u8
    }
}

impl TryFrom<u8> for TrackId {
    type Error = crate::error::BoxError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::VideoHq),
            1 => Ok(Self::VideoLq),
            2 => Ok(Self::CriticalAudio),
            3 => Ok(Self::Telemetry),
            _ => Err(GatewayError::new(format!(
                "track must be in the stable range 0..=3, received {value}"
            ))
            .boxed()),
        }
    }
}

/// Regla inmutable `Stream ID + program/PID -> Track`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouteRule {
    /// Etiqueta segura y de baja cardinalidad para observabilidad.
    pub source: String,
    /// Stream ID exacto usado para autorización; nunca se registra.
    pub stream_id: String,
    /// Programa MPEG-TS esperado.
    pub program_number: u16,
    /// PID elemental esperado.
    pub pid: u16,
    /// Track lógico de destino.
    pub track: TrackId,
}

/// Tabla completamente validada con una única fuente por Track.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouteTable {
    rules: Vec<RouteRule>,
}

impl RouteTable {
    /// Construye una tabla y rechaza fuentes o destinos ambiguos.
    ///
    /// # Errors
    ///
    /// Devuelve error si faltan Tracks, existen duplicados o algún campo
    /// excede los límites MPEG-TS/SRT.
    pub fn new(rules: Vec<RouteRule>) -> GatewayResult<Self> {
        if rules.len() != TRACK_COUNT {
            return Err(GatewayError::new(format!(
                "routing must define exactly {TRACK_COUNT} rules, one per Track"
            ))
            .boxed());
        }

        let mut tracks = HashSet::with_capacity(TRACK_COUNT);
        let mut route_keys = HashSet::with_capacity(TRACK_COUNT);
        let mut source_stream_ids = std::collections::HashMap::new();
        let mut stream_id_sources = std::collections::HashMap::new();

        for rule in &rules {
            validate_rule(rule)?;
            if !tracks.insert(rule.track) {
                return Err(GatewayError::new(format!(
                    "Track {} is claimed by more than one source",
                    rule.track.value()
                ))
                .boxed());
            }
            if !route_keys.insert((rule.stream_id.clone(), rule.program_number, rule.pid)) {
                return Err(GatewayError::new(
                    "duplicate Stream ID + program_number + PID routing key",
                )
                .boxed());
            }

            match source_stream_ids.get(&rule.source) {
                Some(stream_id) if stream_id != &rule.stream_id => {
                    return Err(GatewayError::new(format!(
                        "source label '{}' refers to multiple Stream IDs",
                        rule.source
                    ))
                    .boxed());
                }
                Some(_) => {}
                None => {
                    source_stream_ids.insert(rule.source.clone(), rule.stream_id.clone());
                }
            }
            match stream_id_sources.get(&rule.stream_id) {
                Some(source) if source != &rule.source => {
                    return Err(GatewayError::new(
                        "one Stream ID cannot use multiple source labels",
                    )
                    .boxed());
                }
                Some(_) => {}
                None => {
                    stream_id_sources.insert(rule.stream_id.clone(), rule.source.clone());
                }
            }
        }

        Ok(Self { rules })
    }

    /// Deserializa y valida la configuración JSON.
    ///
    /// # Errors
    ///
    /// Devuelve error ante JSON inválido o una tabla ambigua/incompleta.
    pub fn from_json(json: &str) -> GatewayResult<Self> {
        let definitions: Vec<RouteDefinition> = serde_json::from_str(json).map_err(|source| {
            GatewayError::with_source("TEREMOQ_ROUTES_JSON is invalid", Box::new(source)).boxed()
        })?;
        let mut rules = Vec::with_capacity(definitions.len());
        for definition in definitions {
            rules.push(RouteRule {
                source: definition.source,
                stream_id: definition.stream_id,
                program_number: definition.program_number,
                pid: definition.pid,
                track: TrackId::try_from(definition.track)?,
            });
        }
        Self::new(rules)
    }

    /// Autoriza un Stream ID y devuelve su etiqueta segura para logs.
    #[must_use]
    pub fn source_for_stream(&self, stream_id: &str) -> Option<&str> {
        self.rules
            .iter()
            .find(|rule| rule.stream_id == stream_id)
            .map(|rule| rule.source.as_str())
    }

    /// Resuelve una unidad elemental al Track configurado.
    #[must_use]
    pub fn resolve(&self, stream_id: &str, program_number: u16, pid: u16) -> Option<TrackId> {
        self.rules
            .iter()
            .find(|rule| {
                rule.stream_id == stream_id
                    && rule.program_number == program_number
                    && rule.pid == pid
            })
            .map(|rule| rule.track)
    }

    /// Devuelve las reglas validadas para diagnóstico o demux futuro.
    #[must_use]
    pub fn rules(&self) -> &[RouteRule] {
        &self.rules
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RouteDefinition {
    source: String,
    stream_id: String,
    program_number: u16,
    pid: u16,
    track: u8,
}

fn validate_rule(rule: &RouteRule) -> GatewayResult<()> {
    validate_label("routing source", &rule.source, MAX_SOURCE_LABEL_BYTES)?;
    if rule.stream_id.is_empty() || rule.stream_id.len() > MAX_STREAM_ID_BYTES {
        return Err(GatewayError::new(format!(
            "routing Stream ID must contain 1..={MAX_STREAM_ID_BYTES} bytes"
        ))
        .boxed());
    }
    if rule.program_number == 0 {
        return Err(GatewayError::new("program_number 0 is reserved by MPEG-TS").boxed());
    }
    if !(MIN_ELEMENTARY_PID..=MAX_ELEMENTARY_PID).contains(&rule.pid) {
        return Err(GatewayError::new(format!(
            "PID must be an elementary PID in {MIN_ELEMENTARY_PID}..={MAX_ELEMENTARY_PID}"
        ))
        .boxed());
    }
    Ok(())
}

fn validate_label(name: &str, value: &str, max_len: usize) -> GatewayResult<()> {
    let valid = !value.is_empty()
        && value.len() <= max_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));
    if valid {
        Ok(())
    } else {
        Err(GatewayError::new(format!(
            "{name} must contain 1..={max_len} ASCII letters, digits, '.', '_' or '-'"
        ))
        .boxed())
    }
}

#[cfg(test)]
mod tests {
    use super::{RouteTable, TrackId};

    const VALID_ROUTES: &str = r#"[
        {"source":"main","stream_id":"main","program_number":1,"pid":256,"track":0},
        {"source":"fallback","stream_id":"fallback","program_number":1,"pid":256,"track":1},
        {"source":"main","stream_id":"main","program_number":1,"pid":257,"track":2},
        {"source":"telemetry","stream_id":"telemetry","program_number":1,"pid":300,"track":3}
    ]"#;

    #[test]
    fn resolves_exact_composite_route() -> crate::error::GatewayResult<()> {
        let table = RouteTable::from_json(VALID_ROUTES)?;

        assert_eq!(table.resolve("main", 1, 257), Some(TrackId::CriticalAudio));
        assert_eq!(table.resolve("main", 1, 300), None);
        assert_eq!(table.source_for_stream("main"), Some("main"));
        Ok(())
    }

    #[test]
    fn rejects_duplicate_track_claim() {
        let json = VALID_ROUTES.replace("\"track\":3", "\"track\":2");
        assert!(RouteTable::from_json(&json).is_err());
    }

    #[test]
    fn rejects_source_label_for_multiple_streams() {
        let json = VALID_ROUTES.replace("\"source\":\"telemetry\"", "\"source\":\"main\"");
        assert!(RouteTable::from_json(&json).is_err());
    }

    #[test]
    fn rejects_missing_track() {
        let routes = r#"[
            {"source":"main","stream_id":"main","program_number":1,"pid":256,"track":0},
            {"source":"fallback","stream_id":"fallback","program_number":1,"pid":256,"track":1},
            {"source":"main","stream_id":"main","program_number":1,"pid":257,"track":2}
        ]"#;
        assert!(RouteTable::from_json(routes).is_err());
    }

    #[test]
    fn rejects_stream_id_with_multiple_labels() {
        let json =
            VALID_ROUTES.replace("\"stream_id\":\"telemetry\"", "\"stream_id\":\"fallback\"");
        assert!(RouteTable::from_json(&json).is_err());
    }

    #[test]
    fn rejects_unknown_fields() {
        let json = VALID_ROUTES.replace("\"track\":0", "\"track\":0,\"unexpected\":true");
        assert!(RouteTable::from_json(&json).is_err());
    }
}
