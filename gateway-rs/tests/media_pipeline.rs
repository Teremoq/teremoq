use std::{net::SocketAddr, process::Command, sync::Arc, time::Duration};

use bytes::Bytes;
use gateway_rs::{
    config::GatewayConfig,
    error::{GatewayError, GatewayResult},
    ingest::IngestPacket,
    media::{AccessUnitKind, Codec, GstreamerMediaDemux, MediaDemux},
    observability::EventLogger,
    routing::TrackId,
    scheduler::{ReceiveOutcome, SubscriberId, SubscriberScheduler},
};

const FIXTURE: &[u8] = include_bytes!("fixtures/mpeg2-aac.ts");

#[tokio::test]
async fn demuxes_encoded_video_and_audio_without_transcoding() -> GatewayResult<()> {
    let config = GatewayConfig::new("media-integration", "info", 1_000)?;
    let mut demux = GstreamerMediaDemux::new(
        config.media,
        config.srt.max_sessions,
        config.srt.routes,
        EventLogger::new(config.instance_id),
    )?;
    let peer: SocketAddr = "127.0.0.1:41000".parse()?;
    for (index, chunk) in FIXTURE.chunks(1_316).enumerate() {
        let message_number = u32::try_from(index).map_err(|source| {
            GatewayError::with_source("fixture has too many chunks", Box::new(source)).boxed()
        })?;
        demux.push(IngestPacket {
            payload: Bytes::copy_from_slice(chunk),
            connection_id: Arc::from("fixture-connection"),
            peer,
            stream_id: Arc::from("teremoq-main"),
            message_number,
            srt_timestamp: message_number,
            received_at: tokio::time::Instant::now(),
        })?;
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut video_random = None;
    let mut delta_in_group = None;
    let mut audio = None;
    while tokio::time::Instant::now() < deadline
        && (video_random.is_none() || delta_in_group.is_none() || audio.is_none())
    {
        let result = tokio::time::timeout(Duration::from_millis(250), demux.receive()).await;
        if let Ok(Ok(Some(object))) = result {
            match object.group.track.id {
                TrackId::VideoHq if object.kind == AccessUnitKind::RandomAccess => {
                    video_random = Some(object);
                }
                TrackId::VideoHq
                    if video_random.as_ref().is_some_and(|random| {
                        object.kind == AccessUnitKind::Delta && object.group.id == random.group.id
                    }) =>
                {
                    delta_in_group = Some(object);
                }
                TrackId::CriticalAudio if audio.is_none() => audio = Some(object),
                _ => {}
            }
        }
    }
    let video = video_random.ok_or_else(|| {
        GatewayError::new("fixture produced no random-access HQ video Object").boxed()
    })?;
    let delta = delta_in_group.ok_or_else(|| {
        GatewayError::new("fixture produced no delta Object in the first Group").boxed()
    })?;
    let audio = audio
        .ok_or_else(|| GatewayError::new("fixture produced no critical audio Object").boxed())?;

    assert_eq!(video.codec, Codec::Mpeg2Video);
    assert_eq!(video.kind, AccessUnitKind::RandomAccess);
    assert!(video.group.random_access);
    assert!(video.pts_ns.is_some());
    assert!(video.dts_ns.is_some());
    assert!(!video.payload.is_empty());
    assert_eq!(delta.kind, AccessUnitKind::Delta);
    assert_eq!(delta.group.id, video.group.id);
    assert!(delta.group.random_access);
    assert!(delta.object_id > video.object_id);
    assert_eq!(audio.codec, Codec::Aac);
    assert_eq!(audio.kind, AccessUnitKind::Audio);
    assert!(audio.pts_ns.is_some());
    assert!(!audio.payload.is_empty());

    let scheduler = Arc::new(SubscriberScheduler::new(
        config.scheduler,
        EventLogger::new("media-scheduler-integration".to_owned()),
    ));
    let receiver = scheduler.register(SubscriberId::new("fixture-subscriber")?)?;
    let now = tokio::time::Instant::now();
    scheduler.fanout(video, now)?;
    scheduler.fanout(delta, now)?;
    scheduler.fanout(audio, now)?;
    assert!(matches!(
        receiver.try_receive_at(now)?,
        ReceiveOutcome::Object(object) if object.track == TrackId::CriticalAudio
    ));
    assert_eq!(scheduler.snapshot().accepted, 3);
    demux.shutdown()?;
    Ok(())
}

#[tokio::test]
async fn corrupted_transport_stream_is_isolated() -> GatewayResult<()> {
    let config = GatewayConfig::new("media-corruption", "info", 1_000)?;
    let mut demux = GstreamerMediaDemux::new(
        config.media,
        config.srt.max_sessions,
        config.srt.routes,
        EventLogger::new(config.instance_id),
    )?;
    demux.push(IngestPacket {
        payload: Bytes::from_static(b"not-an-mpeg-transport-stream"),
        connection_id: Arc::from("corrupt-connection"),
        peer: "127.0.0.1:42000".parse()?,
        stream_id: Arc::from("teremoq-main"),
        message_number: 0,
        srt_timestamp: 0,
        received_at: tokio::time::Instant::now(),
    })?;
    tokio::time::sleep(Duration::from_millis(25)).await;
    demux.maintain(tokio::time::Instant::now());
    demux.shutdown()
}

#[tokio::test]
async fn repackages_h264_as_cmaf_without_transcoding() -> GatewayResult<()> {
    assert_h264_track_is_cmaf("teremoq-main", TrackId::VideoHq, "0-video-hq").await
}

#[tokio::test]
async fn repackages_lq_h264_as_cmaf_without_transcoding() -> GatewayResult<()> {
    assert_h264_track_is_cmaf("teremoq-lq", TrackId::VideoLq, "1-video-lq").await
}

async fn assert_h264_track_is_cmaf(
    stream_id: &'static str,
    expected_track: TrackId,
    catalog_track: &'static str,
) -> GatewayResult<()> {
    let fixture = synthetic_h264_transport_stream()?;

    let config = GatewayConfig::new("cmaf-integration", "info", 1_000)?;
    let mut demux = GstreamerMediaDemux::new(
        config.media,
        config.srt.max_sessions,
        config.srt.routes,
        EventLogger::new(config.instance_id),
    )?;
    let received_at = tokio::time::Instant::now();
    for (index, chunk) in fixture.chunks(1_316).enumerate() {
        let message_number = u32::try_from(index).map_err(|source| {
            GatewayError::with_source("fixture has too many chunks", Box::new(source)).boxed()
        })?;
        demux.push(IngestPacket {
            payload: Bytes::copy_from_slice(chunk),
            connection_id: Arc::from("cmaf-fixture-connection"),
            peer: "127.0.0.1:43000".parse()?,
            stream_id: Arc::from(stream_id),
            message_number,
            srt_timestamp: message_number,
            received_at,
        })?;
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut random_access = None;
    let mut delta = None;
    while tokio::time::Instant::now() < deadline && (random_access.is_none() || delta.is_none()) {
        if let Ok(Ok(Some(object))) =
            tokio::time::timeout(Duration::from_millis(250), demux.receive()).await
        {
            if object.group.track.id != expected_track {
                continue;
            }
            match object.kind {
                AccessUnitKind::RandomAccess if random_access.is_none() => {
                    random_access = Some(object);
                }
                AccessUnitKind::Delta if delta.is_none() => delta = Some(object),
                _ => {}
            }
        }
    }

    let random_access = random_access.ok_or_else(|| {
        GatewayError::new("H.264 fixture produced no CMAF keyframe chunk").boxed()
    })?;
    let delta = delta
        .ok_or_else(|| GatewayError::new("H.264 fixture produced no CMAF delta chunk").boxed())?;
    assert_eq!(random_access.codec, Codec::H264);
    assert!(gateway_rs::cmsf::cmaf_chunk_is_random_access(
        &random_access.payload
    )?);
    assert!(!gateway_rs::cmsf::cmaf_chunk_is_random_access(
        &delta.payload
    )?);
    assert_eq!(random_access.payload.get(4..8), Some(b"moof".as_slice()));
    assert!(
        random_access
            .payload
            .windows(4)
            .any(|window| window == b"mdat")
    );
    assert_eq!(delta.payload.get(4..8), Some(b"moof".as_slice()));

    let initialization = random_access
        .cmaf_init
        .as_ref()
        .ok_or_else(|| GatewayError::new("CMAF chunk did not retain its initialization").boxed())?;
    assert_eq!(initialization.get(4..8), Some(b"ftyp".as_slice()));
    assert!(initialization.windows(4).any(|window| window == b"moov"));
    let metadata = gateway_rs::cmsf::h264_metadata(initialization)?;
    assert_eq!(metadata.width, 160);
    assert_eq!(metadata.height, 90);
    assert!(metadata.codec.starts_with("avc1."));
    let catalog = gateway_rs::cmsf::h264_video_catalog(catalog_track, initialization)?;
    let parsed: serde_json::Value = serde_json::from_slice(&catalog)?;
    assert_eq!(parsed["version"], 1);
    assert_eq!(parsed["tracks"][0]["name"], catalog_track);
    assert_eq!(parsed["tracks"][0]["packaging"], "cmaf");
    assert!(parsed["tracks"][0]["initData"].as_str().is_some());
    let multitrack_catalog = gateway_rs::cmsf::h264_video_catalogs(&[
        ("0-video-hq", initialization),
        ("1-video-lq", initialization),
    ])?;
    let parsed_multitrack: serde_json::Value = serde_json::from_slice(&multitrack_catalog)?;
    assert_eq!(
        parsed_multitrack["tracks"].as_array().map(Vec::len),
        Some(2)
    );
    assert_eq!(parsed_multitrack["tracks"][1]["name"], "1-video-lq");
    demux.shutdown()
}

fn synthetic_h264_transport_stream() -> GatewayResult<Vec<u8>> {
    let output = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=160x90:rate=10",
            "-t",
            "1.2",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-tune",
            "zerolatency",
            "-g",
            "10",
            "-keyint_min",
            "10",
            "-sc_threshold",
            "0",
            "-bf",
            "0",
            "-f",
            "mpegts",
            "pipe:1",
        ])
        .output()
        .map_err(|source| {
            GatewayError::with_source(
                "failed to generate synthetic H.264 fixture",
                Box::new(source),
            )
            .boxed()
        })?;
    if !output.status.success() {
        return Err(GatewayError::new(format!(
            "FFmpeg H.264 fixture generation failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
        .boxed());
    }

    Ok(output.stdout)
}
