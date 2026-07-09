//
//  PaladalaFFmpegShim.h
//  Paladala
//
//  Swift 6 / Xcode 16 forward-imports FFmpeg's `typedef struct
//  AVFormatContext AVFormatContext;` (and the other pointer-typedef'd
//  structs) as *empty struct values*, so Swift sees types like
//  `AVFormatContext` with no readable members.  Calls like
//  `ctx.pointee.duration` and `fmtCtx.pointee.streams[i].pointee.codecpar`
//  produce "value of type 'AVFormatContext' has no member '...'".
//
//  The fix: declare here the small set of struct-field accessors
//  Swift needs, implement them in PaladalaFFmpegShim.c, and let
//  Swift call those plain C functions instead.  All real FFmpeg
//  semantics happen in C — Swift just passes opaque pointers
//  through to these helpers and the upstream FFmpeg API.
//
//  Surface area kept minimal: only the fields Phase 0 reads.
//
//  Threading: every shim just dereferences a pointer and returns
//  a scalar / borrowed pointer.  They must be called from the same
//  thread that owns the source object (no synchronization here on
//  purpose — libavformat is not reentrant for shared objects).
//

#ifndef Paladala_FFmpegShim_h
#define Paladala_FFmpegShim_h

#include <stdint.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: AVFormatContext accessors

/// `ctx->duration` in AV_TIME_BASE units (microseconds).
/// May be AV_NOPTS_VALUE for live streams.
int64_t   paladala_format_duration(const AVFormatContext *ctx);

/// `ctx->nb_streams` — number of streams in the container.
unsigned int paladala_format_nb_streams(const AVFormatContext *ctx);

/// `ctx->streams[idx]->codecpar` — borrowed pointer (do NOT free).
/// Returns NULL if idx is out of range.
AVCodecParameters *
paladala_format_stream_codecpar(AVFormatContext *ctx, unsigned int idx);

/// `ctx->streams[idx]->time_base` — the stream's native PTS units.
AVRational paladala_format_stream_time_base(const AVFormatContext *ctx,
                                            unsigned int idx);

// MARK: AVCodecParameters accessors

/// `par->codec_id` (AV_CODEC_ID_H264 / AV_CODEC_ID_HEVC / …).
AVCodecID paladala_codecpar_codec_id(const AVCodecParameters *par);

/// `par->codec_tag` — the FourCC-style codec tag.  Often 0 for
/// MP4 but populated by MPEG-TS / FLV demuxers; preserved for
/// the rare VideoToolbox configuration that needs it.
uint32_t paladala_codecpar_codec_tag(const AVCodecParameters *par);

/// `par->extradata` — borrowed pointer to the codec config
/// record (SPS/PPS for H.264, VPS/SPS/PPS for HEVC; AVCC or
/// HVCC length-prefixed NALU layout).
uint8_t *paladala_codecpar_extradata(const AVCodecParameters *par);

/// `par->extradata_size`.
int      paladala_codecpar_extradata_size(const AVCodecParameters *par);

// MARK: AVPacket accessors

/// `pkt->pts` — presentation timestamp in the stream's time base.
int64_t  paladala_packet_pts(const AVPacket *pkt);

/// `pkt->dts` — decode timestamp.
int64_t  paladala_packet_dts(const AVPacket *pkt);

/// `pkt->stream_index`.
int      paladala_packet_stream_index(const AVPacket *pkt);

/// `pkt->data` — borrowed pointer to compressed frame bytes.
uint8_t *paladala_packet_data(const AVPacket *pkt);

/// `pkt->size` — byte count of `data`.
int      paladala_packet_size(const AVPacket *pkt);

/// `pkt->flags & AV_PKT_FLAG_KEY` — 1 if this packet is a key
/// frame (IDR or equivalent).
int      paladala_packet_is_key(const AVPacket *pkt);

#ifdef __cplusplus
}
#endif

#endif /* Paladala_FFmpegShim_h */
