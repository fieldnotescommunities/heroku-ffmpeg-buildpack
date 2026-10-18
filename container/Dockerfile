# Builds the trimmed ffmpeg for one Heroku stack, in that stack's own build image, so the result links exactly the
# shared libraries the run image carries. Outputs land in /out: the tarball, its sha256, and the build's
# configuration log. Driven by ../build.sh; the shape follows fieldnotescommunities/heroku-libvips-buildpack and the
# component choices are the ones the Field Notes webapp's media pipeline uses (its plans/2026-10-18_build_ffmpeg/).
#
#   docker buildx build --platform linux/amd64 --build-arg STACK_VERSION=26 --build-arg FFMPEG_VERSION=8.1.3 \
#     -f container/Dockerfile -t ffmpeg-heroku-26:8.1.3 container

ARG STACK_VERSION=26
FROM heroku/heroku:${STACK_VERSION}-build

ARG STACK_VERSION
ARG FFMPEG_VERSION
USER root
ENV DEBIAN_FRONTEND=noninteractive
# the configure step below builds its option list in a bash array; Docker's default /bin/sh is dash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Headers for the three libraries we link (the run image has libx264-165, libass9 and libdav1d7 because Heroku's
# own ffmpeg buildpack needs them) and the assembler x264's and ffmpeg's SIMD code wants. zlib1g-dev is in the
# build image already; listed so the build does not depend on the image keeping it. Nothing here adds a run-time
# dependency the image lacks: test/check.sh proves that with ldd in the run image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    nasm \
    pkgconf \
    libx264-dev \
    libass-dev \
    libdav1d-dev \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/src
COPY checksums.txt .

# The upstream release tarball, verified against checksums.txt (ffmpeg.org publishes a PGP signature but no
# checksum file, so the pin is ours). Python's tarfile unpacks rather than GNU tar: under Docker Desktop's Rosetta
# emulation on an Apple Silicon laptop, Ubuntu 26.04's tar fails every entry with "Function not implemented";
# Python uses plain file calls and works the same there and on an amd64 runner. bin/compile runs on a real dyno
# and uses tar.
RUN curl -fsSL -o "ffmpeg-${FFMPEG_VERSION}.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  && sha256sum --check --ignore-missing checksums.txt \
  && python3 -c 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall(filter="data")' "ffmpeg-${FFMPEG_VERSION}.tar.xz"

# The install prefix is the path the buildpack untars to on a dyno ($HOME/.heroku/ffmpeg with $HOME=/app), so
# nothing baked into the build points anywhere else.
ARG PREFIX=/app/.heroku/ffmpeg

# Every component class is disabled and then enabled by name; `--disable-autodetect` stops configure picking up
# whatever the build image happens to have. Filters are the one class left whole: the ffmpeg command line inserts
# filters of its own (format, aresample, transpose for rotation metadata...) that no argstring names, and filters
# carry few advisories; the decoders and demuxers, where the advisories are, are the lists below. The lists are the
# webapp's must-haves plus what its uploads have been seen to hold (QuickTime, MP4, M4A, a few MPEG-TS, MPEG and
# 3GPP, MP3, WAV, and WebM, Ogg and AV1 from time to time). A decoder that is not here cannot be reached by an
# upload, whatever the file claims to be; an upload that needs one fails by name ("Decoder not found"), which is
# the cue to add it and bump.
#
# The names are configure's component names (libavcodec/allcodecs.c, parsers.c, bitstream_filters.c,
# libavformat/allformats.c, protocols.c), which differ from what `ffmpeg -decoders` etc. print for a few: the
# encoder of mov_text is `movtext`, the "mpeg" program-stream demuxer is `mpegps` and its muxer `mpeg1system`,
# the "3gp" muxer is `tgp`, the decoder of codec flv1 is `flv`. A name configure does not know is only a warning
# ("did not match anything"), not an error: test/check.sh's comparison with test/expected_capabilities.txt is
# what catches a component that silently failed to get in.
#
#   decoders: `mp3float` / `mp2float` are the float decoders of mp3 / mp2, `libdav1d` the AV1 software decoder
#             (ffmpeg's own `av1` decoder needs hardware acceleration), `amrnb` / `amrwb` ffmpeg's own (no
#             opencore), `subrip` what the subtitles filter and `-c:s mov_text` read an SRT through
#   encoders: the four outputs the pipeline makes; everything else is a stream copy
#   demuxers: `mov` is QuickTime, MP4, M4A and 3GP in one; `matroska` is Matroska and WebM in one; `concat` and
#             `srt` are inputs the pipeline itself writes
#   muxers:   the four outputs, plus one per video container the demuxers accept so a rotation's stream copy can
#             write back under the original's name
#   parsers:  one per decoder above that has one (the mp3 demuxer and the vp9 decoder select theirs anyway)
#   bsfs:     what the command line inserts for a stream copy between container families; the mov, matroska,
#             flv and mpegts muxers select aac_adtstoasc, vp9_superframe and the mp4toannexb ones themselves, so
#             the list only adds extract_extradata and av1_frame_merge and names the rest for the record
RUN cd "ffmpeg-${FFMPEG_VERSION}" \
  && DECODERS="h264 hevc mpeg4 flv mjpeg png mpeg2video mpeg1video h263 vp8 vp9 libdav1d \
               aac mp3float pcm_s16le pcm_s24le pcm_f32le alac ac3 mp2float amrnb amrwb opus vorbis \
               subrip" \
  && ENCODERS="libx264 aac mjpeg movtext" \
  && DEMUXERS="mov matroska ogg mp3 wav flv mpegts mpegps srt concat" \
  && MUXERS="mp4 mov ipod tgp matroska webm flv mpegts mpeg1system mjpeg" \
  && PARSERS="h264 hevc mpeg4video mpegvideo h263 mjpeg png vp8 vp9 av1 aac mpegaudio ac3 opus vorbis" \
  && BSFS="extract_extradata aac_adtstoasc h264_mp4toannexb hevc_mp4toannexb vp9_superframe av1_frame_merge" \
  && PROTOCOLS="file pipe" \
  && opts=() \
  && for name in ${DECODERS}; do opts+=("--enable-decoder=${name}"); done \
  && for name in ${ENCODERS}; do opts+=("--enable-encoder=${name}"); done \
  && for name in ${DEMUXERS}; do opts+=("--enable-demuxer=${name}"); done \
  && for name in ${MUXERS}; do opts+=("--enable-muxer=${name}"); done \
  && for name in ${PARSERS}; do opts+=("--enable-parser=${name}"); done \
  && for name in ${BSFS}; do opts+=("--enable-bsf=${name}"); done \
  && for name in ${PROTOCOLS}; do opts+=("--enable-protocol=${name}"); done \
  && ./configure \
    --prefix="${PREFIX}" \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-avdevice \
    --disable-network \
    --disable-devices \
    --disable-hwaccels \
    --disable-autodetect \
    --enable-zlib \
    --enable-gpl \
    --enable-libx264 \
    --enable-libass \
    --enable-libdav1d \
    --disable-decoders \
    --disable-encoders \
    --disable-demuxers \
    --disable-muxers \
    --disable-parsers \
    --disable-bsfs \
    --disable-protocols \
    "${opts[@]}" \
  && make -j"$(nproc)" \
  && make install

ENV PATH="${PREFIX}/bin:${PATH}"

# Trim and package: the libav* libraries are static inside the two binaries, so `lib`, `include` and `share` (ffpreset
# files, examples) are not needed on a dyno. The config log records what the build is and can do; the listings are
# what test/check.sh compares with test/expected_capabilities.txt.
RUN cd "${PREFIX}" \
  && rm -rf include lib share \
  && strip --strip-unneeded bin/* \
  && name="ffmpeg-${FFMPEG_VERSION}-heroku-${STACK_VERSION}-$(dpkg --print-architecture)" \
  && mkdir -p /out \
  && python3 -c 'import sys, tarfile; t = tarfile.open(sys.argv[1], "w:gz"); [t.add(d) for d in sys.argv[2:]]; t.close()' "/out/${name}.tar.gz" bin \
  && (cd /out && sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256") \
  && { for listing in version buildconf decoders encoders demuxers muxers filters bsfs protocols; do \
         echo "\$ ffmpeg -${listing}"; ffmpeg -hide_banner "-${listing}"; echo; \
       done; echo "\$ ffprobe -version"; ffprobe -hide_banner -version; } > "/out/${name}.config.log" \
  && ls -l /out
