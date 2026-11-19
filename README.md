## AWS Lambda Node.js Runtime

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/aws/aws-lambda-nodejs-runtime/badge)](https://scorecard.dev/viewer/?uri=github.com/aws/aws-lambda-nodejs-runtime)

This repository contains the source and build definition of the AWS Lambda Node.js runtime
image. The image holds everything a Node.js function needs to run on Lambda: Amazon Linux system
libraries, Node.js, the AWS SDK for JavaScript v3, root certificates and the Lambda
[Runtime Interface Client](https://github.com/aws/aws-lambda-nodejs-runtime-interface-client)
(RIC). The RIC integrates with the
[Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html) to receive
invocation requests from the Lambda service, call your function's handler and return its
response.

The image is built from upstream sources: Node.js, OpenSSL and the GCC runtime library are
compiled from their release tarballs, each pinned by SHA-256, and every npm package is pinned
by its integrity hash in a committed lockfile.

## Supported runtimes

| Runtime | Node.js | Architectures | Variants |
|---|---|---|---|
| `nodejs26.x` | 26 | `arm64`, `amd64` | `mainline`, `DurableFunction` |

The `DurableFunction` variant adds the
[Durable Execution SDK](https://www.npmjs.com/package/@aws/durable-execution-sdk-js) for
Lambda durable functions.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with `buildx`, using the
  [containerd image store](https://docs.docker.com/engine/storage/containerd/). Builds are
  reproducible on Docker 29 or later.
- [Node.js](https://nodejs.org/) 18 or later, to run the tests.

## Building an image

```sh
./build.sh 26 linux/arm64                    # nodejs26.x for arm64
./build.sh 26 linux/amd64                    # nodejs26.x for amd64
./build.sh 26 linux/arm64 DurableFunction    # the DurableFunction variant
```

The image is tagged `lambda-runtime/image:nodejs26.x-<variant>-<arch>`, for example
`lambda-runtime/image:nodejs26.x-mainline-arm64`. `build.sh` documents the other targets and the
environment variables it reads, such as `REGISTRY_MIRROR` and `NPMRC` for building behind a
registry mirror.

The first build compiles GCC, OpenSSL and Node.js; later builds take `/var/lang` from the build
cache. To reuse a built `/var/lang` without the cache, push `lambda-runtime/lang:nodejs26.x-<arch>` to a registry you control and set
`LANG_IMAGE` to it by digest.

On Docker 29 or later, building the same commit twice gives the same image, apart from the
package database of the base image. File timestamps come from the latest commit. Earlier Docker
versions cannot rewrite layer timestamps in the containerd image store, so image digests differ
from one build to the next.

## Testing

The tests run handlers in the image through the
[Lambda Runtime Interface Emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator).

```sh
# Smoke tests
node test/run.mjs lambda-runtime/image:nodejs26.x-mainline-arm64 linux/arm64

# Security tests
node test/run.mjs lambda-runtime/image:nodejs26.x-mainline-arm64 linux/arm64 test/security-cases.json
```

The smoke tests run CommonJS and ES module handlers, use the bundled SDK through `require` and
`import`, and import an ES module from a layer.

The security tests check that:

- the algorithms OpenSSL is configured without are unavailable, with and without the legacy
  provider, TLS 1.2 is the minimum version, and no weak TLS cipher is offered;
- `node` is position-independent with full RELRO, a non-executable stack and stack protection,
  and no shipped library has an executable stack;
- no file in `/var/lang` or `/var/runtime` is world-writable;
- the experimental FFI module is disabled by default;
- a TLS profile is applied only when `AWS_LAMBDA_TLS_PROFILE` asks for one, an `OPENSSL_CONF`
  set by the function takes precedence over it, and an unknown profile fails initialization.

## Repository layout

```text
Dockerfile                 the build: base OS, /var/lang, /var/runtime and the final image
build.sh                   runs the build
builder-images.env         images used only during the build, pinned by digest
base/                      the base image and the entrypoint, shared by every runtime
runtimes/nodejs26.x/
  lang.env                 Node.js, OpenSSL and GCC versions, each pinned by SHA-256
  versions.env             the Node.js major version
  patches/                 patches applied to Node.js
  locks/                   expected root certificates and globals, checked during the build
  sdk/                     the AWS SDK packages, locked; update.sh updates them
  ric/                     the Runtime Interface Client, locked
  durable/                 the Durable Execution SDK, locked
  bootstrap, resolve-tls-profile.sh, tls-profiles/, ca-cert.pem, THIRD-PARTY-LICENSES.txt
test/                      smoke and security tests
.github/workflows/
  build-image.yml          builds and tests every architecture on each pull request
```

## Continuous integration

`.github/workflows/build-image.yml` builds the image for each architecture on a native runner
and runs the smoke and security tests, on every pull request and every push to `main`. On a push
to `main` it also publishes each image to Amazon ECR, tagged `<commit>-<arch>`. Published images
are signed with AWS Signer and carry a SLSA provenance attestation.

## Security

If you discover a potential security issue in this project, we ask that you notify AWS/Amazon
Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/).
Please do **not** create a public GitHub issue.
