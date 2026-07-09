//
//  PaladalaFFmpegShim.c
//  Paladala
//
//  Implementation for PaladalaFFmpegShim.h.  See that file for the
//  why; in short, these 12 accessors let Swift 6 read a handful of
//  FFmpeg struct fields without fighting Xcode 16's importer.
//
//  Every function is a one-line field access.  No allocations, no
//  mutation, no FFmpeg API calls — Swift's opaque-type view of
//  these structs is misleading but harmless; the real struct
//  layout is decided by libavformat / libavcodec at link time.
//

#include "PaladalaFFmpegShim.h"

#include <string.h> // for memset/return-zero on invalid input
#include <libavutil/error.h> // for AVERROR_EOF (AV_NOPTS_VALUE comes from <libavutil/avutil.h> via the .h)

// MARK: AVFormatContext

int64_t paladala_format_duration(const AVFormatContext *ctx) {
    if (!ctx) return AV_NOPTS_VALUE;
    return ctx->duration;
}

unsigned int paladala_format_nb_streams(const AVFormatContext *ctx) {
    if (!ctx) return 0;
    return ctx->nb_streams;
}

AVCodecParameters *
paladala_format_stream_codecpar(AVFormatContext *ctx, unsigned int idx) {
    if (!ctx) return NULL;
    if (idx >= ctx->nb_streams) return NULL;
    AVStream *stream = ctx->streams[idx];
    if (!stream) return NULL;
    return stream->codecpar;
}

AVRational paladala_format_stream_time_base(const AVFormatContext *ctx,
                                             unsigned int idx) {
    AVRational zero = { 0, 1 };
    if (!ctx) return zero;
    if (idx >= ctx->nb_streams) return zero;
    AVStream *stream = ctx->streams[idx];
    if (!stream) return zero;
    return stream->time_base;
}

// MARK: AVCodecParameters

// FFmpeg 7.x has no `typedef enum AVCodecID AVCodecID` — see
// PaladalaFFmpegShim.h for the rationale.  Use the full enum tag
// in the definition to match the declaration.
enum AVCodecID paladala_codecpar_codec_id(const AVCodecParameters *par) {
    if (!par) return AV_CODEC_ID_NONE;
    return par->codec_id;
}

uint32_t paladala_codecpar_codec_tag(const AVCodecParameters *par) {
    if (!par) return 0;
    return par->codec_tag;
}

uint8_t *paladala_codecpar_extradata(const AVCodecParameters *par) {
    if (!par) return NULL;
    return par->extradata;
}

int paladala_codecpar_extradata_size(const AVCodecParameters *par) {
    if (!par) return 0;
    return par->extradata_size;
}

// MARK: AVPacket

int64_t paladala_packet_pts(const AVPacket *pkt) {
    if (!pkt) return AV_NOPTS_VALUE;
    return pkt->pts;
}

int64_t paladala_packet_dts(const AVPacket *pkt) {
    if (!pkt) return AV_NOPTS_VALUE;
    return pkt->dts;
}

int paladala_packet_stream_index(const AVPacket *pkt) {
    if (!pkt) return -1;
    return pkt->stream_index;
}

uint8_t *paladala_packet_data(const AVPacket *pkt) {
    if (!pkt) return NULL;
    return pkt->data;
}

int paladala_packet_size(const AVPacket *pkt) {
    if (!pkt) return 0;
    return pkt->size;
}

int paladala_packet_is_key(const AVPacket *pkt) {
    if (!pkt) return 0;
    return (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
}

// MARK: macro wrappers (see header for rationale)

int64_t paladala_av_nopts_value(void) {
    return AV_NOPTS_VALUE;
}

int paladala_averror_eof(void) {
    return AVERROR_EOF;
}
