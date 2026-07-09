//
//  Paladala-Bridging-Header.h
//  Paladala
//
//  Bridges FFmpeg C APIs into Swift.  The CI workflow compiles
//  FFmpeg 7.1.1 as a static archive (see scripts/build-ffmpeg.sh)
//  and the App target's HEADER_SEARCH_PATHS points at the install
//  root so the #import paths below resolve at compile time.
//
//  Only the FFmpeg headers we actually consume are imported here —
//  keeping the bridging header narrow reduces the chance of a
//  symbol collision with the iOS SDK (FFmpeg has its own BOOL,
//  uint64_t etc. that can clash with system headers if imported
//  indiscriminately).
//
//  Consumed modules (see scripts/build-ffmpeg.sh for the enable
//  list that determines what's actually inside the static archive):
//    libavformat  — demuxers (MP4 / HLS / FLV) + AVIO
//    libavcodec   — packet/codec structures + H.264/HEVC parsers
//    libavutil    — frame, dictionary, error helpers, math
//    libswresample — audio resample (Phase 2; imported now so the
//                    header is on the search path when we get there)
//

#ifndef Paladala_Bridging_Header_h
#define Paladala_Bridging_Header_h

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>

#endif /* Paladala_Bridging_Header_h */
