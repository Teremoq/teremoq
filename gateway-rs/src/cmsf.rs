//! Catálogo MSF/CMSF generado a partir de la inicialización CMAF real.

use std::io::{Cursor, Seek};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use bytes::Bytes;
use mp4::ReadBox;
use serde::Serialize;

use crate::error::{GatewayError, GatewayResult};

/// Nombre del Track de catálogo definido por MSF.
pub const CATALOG_TRACK: &str = "catalog";

/// Metadatos H.264 extraídos del `moov`, sin inspeccionar píxeles.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CmafVideoMetadata {
    /// Codec RFC 6381, por ejemplo `avc1.42c00d`.
    pub codec: String,
    /// Anchura codificada declarada en `avc1`.
    pub width: u16,
    /// Altura codificada declarada en `avc1`.
    pub height: u16,
}

/// Genera un catálogo MSF versión 1 para una representación H.264/CMAF.
///
/// # Errors
///
/// Rechaza inicializaciones truncadas, sin `ftyp`/`moov` o sin una entrada
/// `avc1` válida. El payload resultante queda acotado por el tamaño de la
/// inicialización que ya limita el pipeline multimedia.
pub fn h264_video_catalog(track_name: &str, init: &Bytes) -> GatewayResult<Bytes> {
    h264_video_catalogs(&[(track_name, init)])
}

/// Genera un único catálogo MSF para varias representaciones H.264/CMAF.
///
/// # Errors
///
/// Rechaza catálogos vacíos, nombres duplicados, más de dos representaciones
/// de vídeo o cualquier inicialización CMAF inválida.
pub fn h264_video_catalogs(tracks: &[(&str, &Bytes)]) -> GatewayResult<Bytes> {
    if tracks.is_empty() || tracks.len() > 2 {
        return Err(GatewayError::new("MSF video catalog must contain one or two tracks").boxed());
    }
    if tracks.len() == 2 && tracks[0].0 == tracks[1].0 {
        return Err(GatewayError::new("MSF video catalog contains duplicate track names").boxed());
    }
    let tracks = tracks
        .iter()
        .map(|(track_name, init)| {
            let metadata = h264_metadata(init)?;
            Ok(CatalogTrack {
                name: (*track_name).to_owned(),
                packaging: "cmaf",
                role: "video",
                is_live: true,
                codec: metadata.codec,
                width: metadata.width,
                height: metadata.height,
                init_data: STANDARD.encode(init),
            })
        })
        .collect::<GatewayResult<Vec<_>>>()?;
    let catalog = Catalog { version: 1, tracks };
    serde_json::to_vec(&catalog)
        .map(Bytes::from)
        .map_err(|source| {
            GatewayError::with_source("failed to serialize MSF catalog", Box::new(source)).boxed()
        })
}

/// Extrae la configuración AVC del segmento de inicialización CMAF.
///
/// # Errors
///
/// Devuelve error ante cajas ISO-BMFF inválidas o un codec distinto de H.264.
pub fn h264_metadata(init: &Bytes) -> GatewayResult<CmafVideoMetadata> {
    let mut cursor = Cursor::new(init.as_ref());
    let init_len = u64::try_from(init.len()).map_err(|source| {
        GatewayError::with_source(
            "CMAF initialization length does not fit u64",
            Box::new(source),
        )
        .boxed()
    })?;
    let mut has_ftyp = false;
    let mut metadata = None;

    while cursor.position() < init_len {
        let start = cursor.position();
        let header = mp4::BoxHeader::read(&mut cursor).map_err(|source| {
            GatewayError::with_source("failed to read CMAF initialization box", Box::new(source))
                .boxed()
        })?;
        if header.size < mp4::HEADER_SIZE || header.size > init_len.saturating_sub(start) {
            return Err(GatewayError::new("invalid CMAF initialization box size").boxed());
        }
        match header.name {
            mp4::BoxType::FtypBox => has_ftyp = true,
            mp4::BoxType::MoovBox => {
                let moov = mp4::MoovBox::read_box(&mut cursor, header.size).map_err(|source| {
                    GatewayError::with_source(
                        "failed to parse CMAF movie initialization",
                        Box::new(source),
                    )
                    .boxed()
                })?;
                metadata = Some(video_metadata_from_moov(&moov)?);
            }
            _ => {}
        }
        cursor
            .seek(std::io::SeekFrom::Start(start.saturating_add(header.size)))
            .map_err(|source| {
                GatewayError::with_source(
                    "failed to advance through CMAF initialization",
                    Box::new(source),
                )
                .boxed()
            })?;
    }
    if !has_ftyp {
        return Err(GatewayError::new("CMAF initialization has no ftyp box").boxed());
    }
    metadata.ok_or_else(|| GatewayError::new("CMAF initialization has no moov box").boxed())
}

/// Determina si un chunk CMAF comienza con una muestra de acceso aleatorio.
///
/// La decisión se obtiene de `tfhd`/`trun`, que son la autoridad ISO-BMFF.
/// No depende de flags del buffer externo de `GStreamer`, ya que un `BufferList`
/// puede agrupar varias cajas con flags distintas.
///
/// # Errors
///
/// Rechaza payloads truncados, sin una primera caja `moof` válida o sin una
/// descripción de muestras que permita localizar una muestra independiente.
pub fn cmaf_chunk_is_random_access(payload: &Bytes) -> GatewayResult<bool> {
    let mut cursor = Cursor::new(payload.as_ref());
    let payload_len = u64::try_from(payload.len()).map_err(|source| {
        GatewayError::with_source("CMAF chunk length does not fit u64", Box::new(source)).boxed()
    })?;
    let header = mp4::BoxHeader::read(&mut cursor).map_err(|source| {
        GatewayError::with_source("failed to read CMAF fragment header", Box::new(source)).boxed()
    })?;
    if header.name != mp4::BoxType::MoofBox
        || header.size < mp4::HEADER_SIZE
        || header.size > payload_len
    {
        return Err(GatewayError::new("CMAF chunk does not start with a valid moof box").boxed());
    }
    let moof = mp4::MoofBox::read_box(&mut cursor, header.size).map_err(|source| {
        GatewayError::with_source("failed to parse CMAF movie fragment", Box::new(source)).boxed()
    })?;
    let mut described_sample = false;
    for traf in &moof.trafs {
        let Some(trun) = &traf.trun else {
            continue;
        };
        let default_flags = traf.tfhd.default_sample_flags.unwrap_or_default();
        for sample_index in 0..trun.sample_count {
            described_sample = true;
            let index = usize::try_from(sample_index).map_err(|source| {
                GatewayError::with_source("CMAF sample index does not fit usize", Box::new(source))
                    .boxed()
            })?;
            let mut flags = trun
                .sample_flags
                .get(index)
                .copied()
                .unwrap_or(default_flags);
            if sample_index == 0 {
                flags = trun.first_sample_flags.unwrap_or(flags);
            }
            let sample_depends_on = (flags >> 24) & 0x03;
            let is_non_sync_sample = ((flags >> 16) & 0x01) == 1;
            if sample_depends_on == 2 && !is_non_sync_sample {
                return Ok(true);
            }
        }
    }
    if !described_sample {
        return Err(GatewayError::new("CMAF moof contains no described samples").boxed());
    }
    Ok(false)
}

fn video_metadata_from_moov(moov: &mp4::MoovBox) -> GatewayResult<CmafVideoMetadata> {
    for trak in &moov.traks {
        if let Some(avc1) = &trak.mdia.minf.stbl.stsd.avc1 {
            let codec = rfc6381_codec::Codec::avc1(
                avc1.avcc.avc_profile_indication,
                avc1.avcc.profile_compatibility,
                avc1.avcc.avc_level_indication,
            );
            return Ok(CmafVideoMetadata {
                codec: codec.to_string(),
                width: avc1.width,
                height: avc1.height,
            });
        }
    }
    Err(GatewayError::new("CMAF initialization contains no H.264 avc1 track").boxed())
}

#[derive(Serialize)]
struct Catalog {
    version: u8,
    tracks: Vec<CatalogTrack>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CatalogTrack {
    name: String,
    packaging: &'static str,
    role: &'static str,
    is_live: bool,
    codec: String,
    width: u16,
    height: u16,
    init_data: String,
}

#[cfg(test)]
mod tests {
    use bytes::Bytes;

    use super::{cmaf_chunk_is_random_access, h264_metadata};

    #[test]
    fn rejects_non_mp4_initialization() {
        assert!(h264_metadata(&Bytes::from_static(b"not-an-init-segment")).is_err());
    }

    #[test]
    fn rejects_non_mp4_fragment() {
        assert!(cmaf_chunk_is_random_access(&Bytes::from_static(b"not-a-moof")).is_err());
    }
}
