# heroku-ffmpeg-buildpack

A Heroku buildpack that installs our own trimmed, current build of [ffmpeg](https://ffmpeg.org) (`ffmpeg` and
`ffprobe`) on heroku-26, in place of Heroku's
[heroku-buildpack-activestorage-preview](https://github.com/heroku/heroku-buildpack-activestorage-preview).

## Why

Heroku's buildpack installs the ffmpeg Heroku built for the stack (8.1 on heroku-26) and moves to a new version
when Heroku does, so a point release that fixes a vulnerability reaches a dyno when Heroku rebuilds, not when
upstream publishes. This buildpack makes the ffmpeg version ours to move: a fix is a version bump here.

The build is trimmed to what the Field Notes media pipeline uses. Decoders: h264, hevc, mpeg4, flv1, mjpeg, png,
mpeg1/2 video, h263, vp8, vp9, av1 (through libdav1d), aac, mp3, pcm (s16le, s24le, f32le), alac, ac3, mp2,
amr-nb/wb, opus, vorbis, subrip. Encoders: libx264, aac, mjpeg, mov_text. Demuxers: mov (QuickTime, MP4, M4A,
3GP), matroska/webm, ogg, mp3, wav, flv, mpegts, mpeg, srt, concat. Muxers: mp4, mov, ipod, 3gp, matroska, webm,
flv, mpegts, mpeg, mjpeg. Every filter (the ffmpeg command line inserts filters no argstring names). No network,
devices or hardware acceleration. Most ffmpeg advisories are in decoders; a decoder that is not compiled in cannot
be reached by an upload, whatever the file claims to be, and an upload that needs one fails by name
("Decoder not found"), which is the cue to add it and bump. `container/Dockerfile` holds the lists and the reasons.

## What it does

`bin/compile` downloads `ffmpeg-<version>-<stack>-amd64.tar.gz` from this repo's release `ffmpeg-<version>`,
verifies it against the sha256 pinned in `bin/compile`, untars it into `/app/.heroku/ffmpeg`, and writes
`.profile.d/000_ffmpeg.sh`, which prepends `/app/.heroku/ffmpeg/bin` to `PATH`. The libav* libraries are static
inside the two binaries, which link the run image's own shared libraries for the rest: libx264, libass (with
fontconfig, freetype, fribidi, harfbuzz) and libdav1d, every one of them in the image because Heroku's own ffmpeg
buildpack needs it, so nothing else is carried.

## Using it

```
heroku buildpacks:set -i 3 "https://github.com/fieldnotescommunities/heroku-ffmpeg-buildpack.git#<commit>" -a APP
```

Pin to a commit: the commit fixes the version and the sha256 of what is installed. Deploy a commit the app has not
built (a buildpack change only takes effect at a build). The build log shows
`-----> Installing ffmpeg 8.1.3 for heroku-26 (amd64)`, `sha256 verified` and `Installed ffmpeg version 8.1.3`.

## Building a version

The build runs in Docker, in the stack's build image (`heroku/heroku:26-build`), and is then checked in the stack's
run image (`heroku/heroku:26`): `ldd` finds every library, the decoder, encoder, demuxer, muxer, filter, bitstream
filter and protocol lists match the reviewed `test/expected_capabilities.txt`, the pipeline's must-haves are
present by name, and the pipeline's own commands (optimise, poster, audio extraction, rotation, clip with seek and
burnt subtitles, concat, embedded subtitles) run on sample files from the webapp's public sample library
(`test/samples.txt`), each output probing as the kind expected. The same script runs on a laptop (Docker Desktop
must be running; on Apple Silicon it builds the amd64 image under Rosetta, which is why the Dockerfiles unpack with
Python rather than GNU tar) and in GitHub Actions.

```
FFMPEG_VERSION=8.1.3 ./build.sh   # build/ gets the tarball, its .sha256 and the config log
```

Every pull request runs the same build and check for the version `bin/compile` pins. To publish, run the
**Build ffmpeg** workflow by hand (Actions, "Run workflow"; it appears there once the workflow file is on `main`).
That run also puts the tarball, `.sha256` and `.config.log` on the release `ffmpeg-<version>`.

To move to a new version:

1. Hash its release tarball (`ffmpeg-<version>.tar.xz` from https://ffmpeg.org/releases/; ffmpeg publishes a PGP
   signature but no checksum) and add the line to `container/checksums.txt`.
2. Run the workflow for the version.
3. Put the version and the sha256 from the release's `.sha256` asset into `bin/compile`'s `case` for the stack.
4. If `test/check.sh` reported a change in the capability lists, review it and update
   `test/expected_capabilities.txt`.
5. Commit, note it in `CHANGELOG.md`, and move the apps' pin to the new commit (in the webapp,
   `thor media_smoke_test:buildpack_updates --record --buildpack ffmpeg --commit SHA`, then `heroku buildpacks:set`).

A rebuild of the same version keeps the tarball's name; the sha256 pin is what makes that visible.

## Layout

- `bin/detect`, `bin/compile`, `bin/release`: the buildpack.
- `container/Dockerfile`: the build, with the component lists and configure options; `container/checksums.txt`
  pins the source tarballs.
- `container/Dockerfile.test`: the check in the run image.
- `test/check.sh`, `test/expected_capabilities.txt`, `test/samples.txt`, `test/subtitles.srt`: what the check
  asserts, and the sample files and subtitles it runs the pipeline's commands on.
- `build.sh`: runs both for each stack into `build/` (gitignored).
- `.github/workflows/build.yml`: `build.sh` plus the release upload.

## Credits

The layout, the Docker-based build and the run-image check are those of our
[heroku-libvips-buildpack](https://github.com/fieldnotescommunities/heroku-libvips-buildpack); the choice of
libraries and the stack's packages follow Heroku's
[heroku-buildpack-activestorage-preview](https://github.com/heroku/heroku-buildpack-activestorage-preview) (MIT),
whose build formula is why the run image carries them.

## Licence

MIT, see `LICENSE`.
