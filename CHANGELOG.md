# Changelog

## Unreleased

- First build: ffmpeg 8.1.3 for heroku-26, trimmed to the Field Notes media pipeline. Decoders h264, hevc, mpeg4,
  flv1, mjpeg, png, mpeg1/2 video, h263, vp8, vp9, av1 (libdav1d), aac, mp3, pcm (s16le, s24le, f32le), alac, ac3,
  mp2, amr-nb/wb, opus, vorbis, subrip; encoders libx264, aac, mjpeg, mov_text; demuxers mov, matroska/webm, ogg,
  mp3, wav, flv, mpegts, mpeg, srt, concat; muxers mp4, mov, ipod, 3gp, matroska, webm, flv, mpegts, mpeg, mjpeg;
  every filter; no network, devices or hardware acceleration. Links the run image's libx264, libass and libdav1d.
