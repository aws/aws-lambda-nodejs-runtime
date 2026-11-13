#!/bin/sh
# Usage: build.sh MAJOR PLATFORM [VARIANT] [TARGET]
#   build.sh 26 linux/arm64                          lang, mainline runtime, and mainline image
#   build.sh 26 linux/arm64 DurableFunction          the same for the DurableFunction variant
#   build.sh 26 linux/arm64 mainline runtime         lang and the runtime only
#   build.sh 26 linux/arm64 mainline lang            lang only
#   build.sh 26 linux/arm64 mainline base            the base OS image only
#   build.sh 26 linux/arm64 mainline node            any other stage of Dockerfile, for example
#                                                    node, which keeps the Node source tree
# VARIANT is "mainline" (the default) or "DurableFunction", the variant names Lambda uses.
# TARGET is image (the default), runtime, lang, base, or a stage name.
#
# Images are written to the containerd image store, tagged
#   lambda-runtime/lang:nodejs<MAJOR>.x-<arch>
#   lambda-runtime/runtime:nodejs<MAJOR>.x-<VARIANT>-<arch>
#   lambda-runtime/image:nodejs<MAJOR>.x-<VARIANT>-<arch>
#   lambda-runtime/base:al2023-<arch>
#   lambda-runtime/<stage>:nodejs<MAJOR>.x-<arch>
#
# lang is built first and passed to the later builds as the lang build context, so /var/lang
# has its own epoch: layer file timestamps newer than LANG_SOURCE_DATE_EPOCH are rewritten to
# it. It defaults to the timestamp of the latest commit that changed a pinned input of
# /var/lang (builder-images.env, lang.env, patches, locks), so /var/lang changes only when
# they do. Dockerfile edits do not move it.
# For everything else, SOURCE_DATE_EPOCH, which defaults to the latest commit's timestamp, sets
# the runtime-release identifier and the layer timestamps.
#
# Environment:
#   BASE_IMAGE     an image to use as the base instead of building the base stage
#   LANG_IMAGE     an image to use as /var/lang instead of building lang
#                  BuildKit resolves both in their registry before the local image store, and a
#                  name without a registry on Docker Hub, so name them by digest or in a registry
#                  you control
#   BUILDX_FLAGS   passed to docker buildx build, for example "--no-cache"
#   REGISTRY_MIRROR  pull the public.ecr.aws images from this registry instead, for example an
#                  ECR pull-through cache (<account>.dkr.ecr.<region>.amazonaws.com/<prefix>);
#                  the images are pinned by digest, so they are the same images
set -eu

major=$1
platform=$2
variant=${3:-mainline}
target=${4:-image}
root=$(cd "$(dirname "$0")" && pwd)
arch=${platform#linux/}

set -a
. "$root/base/base.env"
. "$root/builder-images.env"
. "$root/runtimes/nodejs${major}.x/lang.env"
. "$root/runtimes/nodejs${major}.x/versions.env"
set +a

if [ -n "${REGISTRY_MIRROR:-}" ]; then
  AL2023_MINIMAL=$REGISTRY_MIRROR/${AL2023_MINIMAL#public.ecr.aws/}
  AL2023=$REGISTRY_MIRROR/${AL2023#public.ecr.aws/}
  AL2023_GCC=$REGISTRY_MIRROR/${AL2023_GCC#public.ecr.aws/}
fi

commit_epoch() {
  epoch=$(git -C "$root" log -1 --format=%ct -- "$@" 2>/dev/null) || epoch=
  if [ -z "$epoch" ]; then
    echo "no commit found for $* in $root; set SOURCE_DATE_EPOCH and LANG_SOURCE_DATE_EPOCH" >&2
    exit 1
  fi
  echo "$epoch"
}
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then SOURCE_DATE_EPOCH=$(commit_epoch .); fi
if [ -z "${LANG_SOURCE_DATE_EPOCH:-}" ]; then
  LANG_SOURCE_DATE_EPOCH=$(commit_epoch builder-images.env \
  "runtimes/nodejs${major}.x/lang.env" "runtimes/nodejs${major}.x/patches" \
  "runtimes/nodejs${major}.x/locks")
fi

case "$variant" in
  mainline) variant_stage=mainline ;;
  DurableFunction) variant_stage=durablefunction ;;
  *) echo "unknown variant: $variant (expected mainline or DurableFunction)" >&2; exit 2 ;;
esac

lang_tag=lambda-runtime/lang:nodejs${major}.x-${arch}

# Rewriting layer timestamps needs an export that does not unpack the image, which Docker
# allows from version 29. On earlier versions the timestamps are left as built, so image
# digests differ from one build to the next.
docker_version=$(docker version -f '{{.Server.Version}}')
if [ "${docker_version%%.*}" -ge 29 ]; then
  output_opts=,rewrite-timestamp=true,unpack=false
else
  output_opts=
  echo "Docker $docker_version cannot rewrite layer timestamps: image digests will not be reproducible" >&2
fi

# build STAGE TAG EPOCH [ARGS...]
build() {
  stage=$1 tag=$2 epoch=$3
  shift 3
  SOURCE_DATE_EPOCH=$epoch docker buildx build ${BUILDX_FLAGS:-} \
    --platform "$platform" \
    --target "$stage" \
    --build-arg BASE_MINIMAL="$AL2023_MINIMAL" \
    --build-arg BUILDER_BASE="$AL2023" \
    --build-arg GCC_BUILDER_BASE="$AL2023_GCC" \
    --build-arg MAJOR_VERSION \
    --build-arg NODE_VERSION --build-arg NODE_SHA256 \
    --build-arg OPENSSL_VERSION --build-arg OPENSSL_SHA256 --build-arg OPENSSL_CONFIGURE_OPTS \
    --build-arg GCC_VERSION --build-arg GCC_SHA256 \
    --build-arg NODE_CONFIGURE_OPTS \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --build-context base-src="$root/base" \
    ${BASE_IMAGE:+--build-context base=docker-image://$BASE_IMAGE} \
    "$@" \
    --output "type=image,name=$tag$output_opts" \
    -f "$root/Dockerfile" \
    "$root"
}

# build_lang builds /var/lang unless LANG_IMAGE supplies it, and sets with_lang to the build
# context that supplies it. The lang it builds is saved from the image store as an OCI layout
# and passed by digest: as a docker-image:// context, lambda-runtime/lang would resolve on
# Docker Hub before the local image store.
build_lang() {
  if [ -n "${LANG_IMAGE:-}" ]; then
    with_lang="--build-context lang=docker-image://$LANG_IMAGE"
    return
  fi
  build lang "$lang_tag" "$LANG_SOURCE_DATE_EPOCH"
  layout=$(mktemp -d)
  trap 'rm -rf "$layout"' EXIT
  docker save "$lang_tag" | tar -x -C "$layout"
  digest=$(grep -o '"digest":"sha256:[0-9a-f]*"' "$layout/index.json" | head -n 1 | cut -d'"' -f4)
  if [ ! -f "$layout/blobs/sha256/${digest#sha256:}" ]; then
    echo "the lang OCI layout in $layout does not contain $digest" >&2
    exit 1
  fi
  with_lang="--build-context lang=oci-layout://$layout@$digest"
}
runtime_tag=lambda-runtime/runtime:nodejs${major}.x-${variant}-${arch}

case "$target" in
  builder-base|gcc|toolchain|openssl|node-src|node)
    build "$target" "lambda-runtime/$target:nodejs${major}.x-${arch}" "$LANG_SOURCE_DATE_EPOCH" ;;
  lang)
    build lang "$lang_tag" "$LANG_SOURCE_DATE_EPOCH" ;;
  base)
    build base "lambda-runtime/base:al2023-${arch}" "$SOURCE_DATE_EPOCH" ;;
  runtime)
    build_lang
    build "$variant_stage" "$runtime_tag" "$SOURCE_DATE_EPOCH" $with_lang ;;
  image)
    build_lang
    build "$variant_stage" "$runtime_tag" "$SOURCE_DATE_EPOCH" $with_lang
    # The runtime image carries a full SLSA provenance attestation.
    build "image-$variant_stage" "lambda-runtime/image:nodejs${major}.x-${variant}-${arch}" "$SOURCE_DATE_EPOCH" $with_lang \
      --provenance=mode=max ;;
  *)
    build_lang
    build "$target" "lambda-runtime/$target:nodejs${major}.x-${arch}" "$SOURCE_DATE_EPOCH" $with_lang ;;
esac
