#!/usr/bin/env bash
# Builds and checks ffmpeg for each stack, into build/. The same script runs on a laptop (Docker Desktop) and in
# the GitHub Actions workflow, which then publishes build/ as release assets.
#
#   FFMPEG_VERSION=8.1.3 ./build.sh                          # heroku-26
#   FFMPEG_VERSION=8.1.3 STACK_VERSIONS="26 28" ./build.sh

set -eu -o pipefail

: "${FFMPEG_VERSION:?set FFMPEG_VERSION, e.g. FFMPEG_VERSION=8.1.3 ./build.sh}"
STACK_VERSIONS="${STACK_VERSIONS:-26}"

cd "$(dirname "$0")"
mkdir -p build

for stack in ${STACK_VERSIONS}; do
  name="ffmpeg-${FFMPEG_VERSION}-heroku-${stack}-amd64"
  image="ffmpeg-heroku-${stack}:${FFMPEG_VERSION}"

  echo "==> building ${name}"
  docker buildx build --platform linux/amd64 --load \
    --build-arg "STACK_VERSION=${stack}" --build-arg "FFMPEG_VERSION=${FFMPEG_VERSION}" \
    -t "${image}" -f container/Dockerfile container

  docker run --rm --platform linux/amd64 -v "${PWD}/build:/build" "${image}" sh -c 'cp /out/* /build/'

  echo "==> checking ${name} in the heroku-${stack} run image"
  docker buildx build --platform linux/amd64 --load \
    --build-arg "STACK_VERSION=${stack}" --build-arg "FFMPEG_VERSION=${FFMPEG_VERSION}" \
    --build-arg "TARBALL=build/${name}.tar.gz" \
    -t "ffmpeg-heroku-${stack}-test:${FFMPEG_VERSION}" -f container/Dockerfile.test .

  echo "==> ${name} built and checked"
done

echo
ls -l build
cat build/*.sha256
