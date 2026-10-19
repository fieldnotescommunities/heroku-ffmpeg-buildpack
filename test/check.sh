#!/usr/bin/env bash
# check.sh <FFMPEG_VERSION> <TEST_DIR>
#
# Run inside the stack's run image with the tarball installed (container/Dockerfile.test). Fails on the first
# thing a dyno would get wrong: a shared library the run image lacks, a component that should not be there (or one
# that should), a must-have missing, or one of the pipeline's own commands failing on a sample file. TEST_DIR holds
# expected_capabilities.txt, samples.txt and subtitles.srt.
#
# The commands are copies of the Field Notes webapp's FfmpegRunner and FfmpegProber argstrings (lib/ffmpeg_runner.rb,
# lib/ffmpeg_prober.rb there); keep them the same. The webapp's smoke test over its whole sample library on a dyno
# is the arbiter; this catches a missing decoder, muxer or auto-inserted component before anything is published.

set -eu -o pipefail

version="$1"
test_dir="$2"
prefix="/app/.heroku/ffmpeg"

fail() {
  echo "CHECK FAILED: $*" >&2
  exit 1
}

echo "==> version"
ffmpeg -version | head -1
[[ "$(ffmpeg -version | head -1)" == "ffmpeg version ${version} "* ]] || fail "ffmpeg -version is not ${version}"
[[ "$(ffprobe -version | head -1)" == "ffprobe version ${version} "* ]] || fail "ffprobe -version is not ${version}"

echo "==> shared libraries (nothing may be 'not found' in the run image)"
for file in "${prefix}/bin/ffmpeg" "${prefix}/bin/ffprobe"; do
  ldd "${file}" | grep -q "not found" && { ldd "${file}"; fail "${file} has unresolved libraries"; }
done
ldd "${prefix}/bin/ffmpeg" | sort
for lib in libx264 libass libdav1d; do
  ldd "${prefix}/bin/ffmpeg" | grep -q "${lib}.so" || fail "ffmpeg does not link ${lib}"
done

echo "==> capabilities"
# one `class name` line per component, as expected_capabilities.txt holds them
capabilities() {
  for class in decoder encoder demuxer muxer; do
    ffmpeg -hide_banner "-${class}s" | awk -v class="${class}" 'sep && NF >= 2 { print class " " $2 } /^ *-+$/ { sep = 1 }'
  done
  ffmpeg -hide_banner -filters | awk '$3 ~ /->/ { print "filter " $2 }'
  ffmpeg -hide_banner -bsfs | awk 'NR > 1 && NF { print "bsf " $1 }'
  ffmpeg -hide_banner -protocols | awk '/^Input:/ { side = "input"; next } /^Output:/ { side = "output"; next } side && NF { print "protocol " side ":" $1 }'
}
listed="$(mktemp)"
capabilities | sort -u > "${listed}"
for class in decoder encoder demuxer muxer filter bsf protocol; do
  printf '%s: %s\n' "${class}" "$(grep -c "^${class} " "${listed}" || true)"
done

# The committed list is the exact set reviewed for the last build; a difference is a change to review (an upstream
# addition or rename, an option that stopped taking effect). A list with no entries yet (first build) only prints
# the set, to be copied into the file.
expected="${test_dir}/expected_capabilities.txt"
if grep -vq '^#' "${expected}"; then
  if ! diff <(grep -v '^#' "${expected}" | sort -u) "${listed}"; then
    fail "the capabilities differ from ${expected##*/} (< expected, > built); review, then update the file"
  fi
  echo "matches ${expected##*/}"
else
  echo "NOTE: ${expected##*/} has no entries yet; copy this list into it once reviewed:"
  cat "${listed}"
fi

echo "==> must-haves (config/media_smoke_test/must_haves.yml in the webapp, by codec, format and filter name)"
# as the webapp checks them: a codec with the D (decoding) or E (encoding) flag in -codecs, a format with D or E in
# -formats (comma-joined names split), a filter by name
codecs="$(ffmpeg -hide_banner -codecs | awk 'sep && NF >= 2 { print $1 " " $2 } /^ *-+$/ { sep = 1 }')"
formats="$(ffmpeg -hide_banner -formats | awk 'sep && NF >= 2 { n = split($2, names, ","); for (i = 1; i <= n; i++) print $1 " " names[i] } /^ *-+$/ { sep = 1 }')"
for name in h264 hevc mpeg4 flv1 aac mp3 pcm_s16le mjpeg; do
  grep -Eq "^D[^ ]* ${name}$" <<< "${codecs}" || fail "must-have decoder ${name} is missing"
done
for name in libx264 aac mjpeg mov_text; do
  grep -Eq "^.E[^ ]* ${name}$" <<< "${codecs}" || grep -q "^encoder ${name}$" "${listed}" || fail "must-have encoder ${name} is missing"
done
for name in mov wav mp3 flv srt concat; do
  grep -Eq "^D[^ ]* ${name}$" <<< "${formats}" || fail "must-have demuxer ${name} is missing"
done
for name in ipod mp4 mov mjpeg; do
  grep -Eq "^.?E ${name}$" <<< "${formats}" || fail "must-have muxer ${name} is missing"
done
for name in scale pad fps subtitles; do
  grep -q "^filter ${name}$" "${listed}" || fail "must-have filter ${name} is missing"
done
echo "all present"

echo "==> the pipeline's commands on the samples"
work="$(mktemp -d)"
srt="${test_dir}/subtitles.srt"
# FfmpegRunner's clip format
CLIP_VIDEO_FLAGS="-c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p"
CLIP_RATE_FLAGS="-crf 23 -preset fast -r 60"
CLIP_SCALE_FILTER="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=60"
CLIP_AUDIO_FLAGS="-c:a aac -b:a 192k -ar 44100 -ac 2"

# @param file; @param kind video|audio|image: the output must exist, be non-empty and probe as that kind. An image
# is checked by its JPEG magic bytes: the pipeline hands a poster to libvips and never reads one back through
# ffprobe, so the build has no image2 or mjpeg demuxer to probe it with
probes_as() {
  local file="$1" kind="$2" codec
  [[ -s "${file}" ]] || fail "${file##*/}: empty or missing output"
  case "${kind}" in
    image) codec="$(head -c 3 "${file}" | od -An -tx1 | tr -d ' \n')"
           [[ "${codec}" == "ffd8ff" ]] || fail "${file##*/}: starts with ${codec}, not a JPEG" ;;
    *)     codec="$(ffprobe -v error -select_streams "${kind:0:1}:0" -show_entries stream=codec_name -of default=nw=1:nk=1 "${file}")"
           [[ -n "${codec}" ]] || fail "${file##*/}: has no ${kind} stream" ;;
  esac
}

run() {
  echo "    \$ ffmpeg $*"
  ffmpeg -hide_banner -loglevel error "$@" || return 1
}

count=0
# the list is read through fd 3: ffmpeg reads its standard input (for the q key), and would otherwise eat the next URL
while read -r url <&3; do
  [[ -z "${url}" || "${url}" == \#* ]] && continue
  name="$(basename "${url}")"
  src="${work}/${name}"
  echo "--- ${name}"
  curl -fsSL --retry 3 -o "${src}" "${url}" || fail "could not download ${url}"
  out="${work}/out-${name}"
  mkdir -p "${out}"

  # FfmpegProber: `ffprobe -v quiet -show_streams -print_format json`
  ffprobe -v quiet -show_streams -print_format json "${src}" > "${out}/probe.json" || fail "${name}: ffprobe failed"
  video_codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "${src}")"
  audio_codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "${src}")"
  echo "    probe: video '${video_codec}' audio '${audio_codec}'"

  case "${name}" in
    *.mpga|*.wav|*.m4a|*.ogg)
      [[ -n "${audio_codec}" ]] || fail "${name}: no audio stream"
      # the audio optimise is FfmpegRunner.optimise_video into an .m4a (what the smoke test does)
      run -i "${src}" -vf 'scale=640:trunc(ow/a/2)*2' -ar 44100 -c:v libx264 -crf 23 -preset fast -profile:v baseline -pix_fmt yuv420p -ab 64k -r 24 -movflags +faststart -y "${out}/optimised.m4a" || fail "${name}: optimise"
      probes_as "${out}/optimised.m4a" audio
      ;;
    *)
      [[ -n "${video_codec}" ]] || fail "${name}: no video stream"
      # optimise_video
      run -i "${src}" -vf 'scale=640:trunc(ow/a/2)*2' -ar 44100 -c:v libx264 -crf 23 -preset fast -profile:v baseline -pix_fmt yuv420p -ab 64k -r 24 -movflags +faststart -y "${out}/optimised.m4v" || fail "${name}: optimise_video"
      probes_as "${out}/optimised.m4v" video
      # extract_poster_image: at 10 s, then without a timestamp (the runner's fallback)
      run -i "${out}/optimised.m4v" -vframes 1 -ss 00:00:10 -f mjpeg -an -y -abort_on empty_output "${out}/poster.jpeg" \
        || run -i "${out}/optimised.m4v" -vframes 1 -f mjpeg -an -y -abort_on empty_output "${out}/poster.jpeg" \
        || fail "${name}: extract_poster_image"
      probes_as "${out}/poster.jpeg" image
      # extract_audio (a video with no audio stream is an expected failure in the smoke test; skipped here)
      if [[ -n "${audio_codec}" ]]; then
        run -i "${src}" -ar 44100 -ab 64k -vn -y "${out}/audio.m4a" || fail "${name}: extract_audio"
        probes_as "${out}/audio.m4a" audio
      fi
      # rotate_video: a stream copy under the original's name; -f mp4 for an .m4v, since the ipod muxer has no HEVC tag
      ext="${name##*.}"
      format_flag=""
      [[ "${ext,,}" == "m4v" ]] && format_flag="-f mp4"
      # shellcheck disable=SC2086
      run -display_rotation 270 -i "${src}" -codec copy ${format_flag} -y "${out}/rotated.${ext}" || fail "${name}: rotate_video"
      probes_as "${out}/rotated.${ext}" video
      # extract_clip from 0.5 s for 2 s, plain and with burnt subtitles
      run -ss 0.5 -i "${src}" -t 2 -map 0:v:0? -map 0:a:0? ${CLIP_VIDEO_FLAGS} -vf "${CLIP_SCALE_FILTER}" ${CLIP_RATE_FLAGS} ${CLIP_AUDIO_FLAGS} -y "${out}/clip.mp4" || fail "${name}: extract_clip"
      probes_as "${out}/clip.mp4" video
      run -ss 0.5 -i "${src}" -t 2 -map 0:v:0? -map 0:a:0? ${CLIP_VIDEO_FLAGS} -vf "${CLIP_SCALE_FILTER},subtitles=${srt}" ${CLIP_RATE_FLAGS} ${CLIP_AUDIO_FLAGS} -y "${out}/clip_burnt.mp4" || fail "${name}: extract_clip with subtitles"
      probes_as "${out}/clip_burnt.mp4" video
      # concat_videos
      printf "file '%s'\nfile '%s'\n" "${out}/clip.mp4" "${out}/clip.mp4" > "${out}/concat.txt"
      run -f concat -safe 0 -i "${out}/concat.txt" -c copy -y "${out}/concat.mp4" || fail "${name}: concat_videos"
      probes_as "${out}/concat.mp4" video
      # embed_subtitles
      run -i "${out}/clip.mp4" -i "${srt}" -c copy -c:s mov_text -y "${out}/embedded.mp4" || fail "${name}: embed_subtitles"
      probes_as "${out}/embedded.mp4" video
      # burn_subtitles over an existing clip
      run -i "${out}/clip.mp4" -vf "subtitles=${srt}" ${CLIP_VIDEO_FLAGS} ${CLIP_RATE_FLAGS} -c:a copy -y "${out}/burnt.mp4" || fail "${name}: burn_subtitles"
      probes_as "${out}/burnt.mp4" video
      ;;
  esac
  count=$((count + 1))
done 3< "${test_dir}/samples.txt"
[[ "${count}" -gt 0 ]] || fail "no samples in samples.txt"
echo "ran the pipeline's commands on ${count} samples"

echo "==> OK"
