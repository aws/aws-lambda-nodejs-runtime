# Lambda Node.js runtime image: open build (proof of concept)

This repository builds the Lambda `nodejs26.x` runtime image from public sources with Docker
alone: no internal build tools, no checked-in binaries. It shows what the build could look like once it moves
to GitHub. It has been tested on arm64 only.

The result matches the managed `nodejs26.x` image closely; see
[How it compares](#how-it-compares-to-the-managed-image).

## What is in here

```text
Dockerfile                 the whole build, in four sections:
                             base     Amazon Linux 2023 minimal plus the two packages the managed base adds
                             lang     /var/lang: GCC 13, OpenSSL, and Node, compiled from source
                             runtime  /var/runtime: bootstrap, TLS profiles, SDK, RIC
                             image    the final image, in the managed image's layer order
build.sh                   runs the build
builder-images.env         images used only to build, pinned by digest
base/                      inputs shared by every runtime: base image, entrypoint
runtimes/nodejs26.x/
  lang.env                 Node, OpenSSL, and GCC versions, each pinned by SHA-256
  versions.env             the Node major
  sdk/                     the managed image's SDK packages, locked; update.sh regenerates them
  patches/                 the two Lambda patches applied to Node
  locks/                   expected root certificates and globals, checked during the build
  bootstrap, resolve-tls-profile.sh, tls-profiles/, ca-cert.pem, THIRD-PARTY-LICENSES.txt
  ric/                     the Runtime Interface Client and its addon's build tools, locked
  durable/                 the Durable Functions SDK, locked
test/                      smoke tests through the public Runtime Interface Emulator
.github/workflows/
  build-image.yml          builds, smoke-tests and pushes the arm64 image on a CodeBuild-hosted runner
```

## Building

You need Docker with `buildx`, using the containerd image store. Reproducible builds need
Docker 29 or later; see below.

```sh
./build.sh 26 linux/arm64                    # mainline runtime image
./build.sh 26 linux/arm64 DurableFunction    # DurableFunction variant
```

The first build compiles GCC, OpenSSL, and Node and takes 1.5–2 hours on 4 cores; after that
`/var/lang` comes from the cache. To reuse a built `/var/lang` without the cache, for example after
`docker builder prune`, push `lambda-runtime/lang:nodejs26.x-arm64` to a registry you control and
set `LANG_IMAGE` to it by digest: BuildKit looks an image name up on its registry before the local
image store, and an unqualified name on Docker Hub. The image is tagged
`lambda-runtime/image:nodejs26.x-<variant>-arm64`. `build.sh` lists the other targets.

Builds are reproducible on Docker 29 or later: the same commit gives a byte-identical image
(apart from the base's package database, see below). File timestamps come from the latest
commit. Docker 28 cannot rewrite layer timestamps in the containerd image store, so there
`build.sh` leaves them as built and image digests differ from one build to the next.

## Testing

```sh
node test/run.mjs lambda-runtime/image:nodejs26.x-mainline-arm64 linux/arm64
```

This runs five handlers (CommonJS, ES module, the bundled SDK through `require` and `import`,
and an ES module import from a layer) through the public Runtime Interface Emulator.

## Building on a CodeBuild-hosted runner

`.github/workflows/build-image.yml` runs the build and the smoke tests on the arm64 CodeBuild
runner project `project-aws-aws-lambda-nodejs-runtime-arm64`, for pull requests to `main`, pushes
to `main` and on manual dispatch. A push also pushes the image to the ECR repository
`aws-lambda-nodejs-runtime`, tagged `<commit>-arm64`, using the role in the `AWS_ROLE_ARN`
secret, which the `deploy` environment's OIDC token may assume. Its runner labels request the
`2xlarge` instance size. These parts of it depend on the runner:

- **Image store.** The build needs Docker's containerd image store, which CodeBuild's Docker
  daemon does not use by default. The workflow restarts `dockerd` with the store enabled, which
  works because a CodeBuild job runs as root on the build host. On a runner that does not run
  as root, the step needs `sudo`.
- **Timeout.** The job allows 120 minutes, the same as the runner project's own timeout.
- **Docker version.** The build uses the Docker that the runner image ships. Images built
  there are reproducible only when it is version 29 or later (see [Building](#building)).
- **Egress.** The build downloads from `public.ecr.aws` (builder images), the Amazon Linux
  package repositories, `ftp.gnu.org` (GCC), `gcc.gnu.org` (the GCC prerequisites),
  `nodejs.org`, `github.com` (OpenSSL and the emulator) and `registry.npmjs.org`. A runner whose
  network firewall allows only GitHub needs all of these allowed. Where `public.ecr.aws` is
  not reachable, set the repository variable `REGISTRY_MIRROR` to an ECR pull-through cache
  of it.

To run the workflow without GitHub, run it with [`act`](https://github.com/nektos/act) on a
CodeBuild host, mapping the job's first runner label to the host:

```sh
act workflow_dispatch -W .github/workflows/build-image.yml \
  -P codebuild-project-aws-aws-lambda-nodejs-runtime-arm64-1-1=-self-hosted
```

`act` evaluates `github.run_id` and `github.run_attempt` as `1`, which gives the `-1-1`
suffix. With `--var REGISTRY_MIRROR=...`, also pass the CodeBuild credential and region
variables through with `--env` so that the workflow can log in to the mirror.

## How it compares to the managed image

The figures in this section and in [The SDK](#the-sdk) were measured on this build of
`nodejs24.x` against the managed `nodejs24.x` arm64 image of October 2026. They have not been
measured again for `nodejs26.x`, which is built from the same recipe with the inputs of the
managed `nodejs26.x` image: Node 26.13.0, its bootstrap, TLS profiles and SDK package versions.

| | Result |
|---|---|
| Base OS packages, environment, entrypoint, bootstrap, config files, certificates, licences | Identical |
| `libstdc++` | Byte-identical |
| `node` | Same code and strings; ICU's objects are linked in a different order, so the binaries differ |
| OpenSSL | Built with the managed runtime's hardened options, so the same ciphers, curves, and hashes are available. The binaries differ: the managed runtime's are built on Amazon Linux 2 with GCC 7.3.1 |
| SDK | The same 553 `@aws-sdk` packages at the same versions; their dependencies, files and size differ (see [The SDK](#the-sdk)) |
| Runtime Interface Client | Public `aws-lambda-ric` from npm, not the internal build; `index.mjs` differs |
| Hard links | Kept in `/var/lang` to reduce bundle size; the managed image ships separate copies |
| `vendor.*` image labels | Left out; they report wrong versions |

## The SDK

`runtimes/nodejs26.x/sdk/package.json` lists the 553 `@aws-sdk` packages the managed image
ships, at its versions (SDK 3.1105.0), and `package-lock.json` is npm's resolution of them. The
build installs them with `npm ci --ignore-scripts`, then `layout.mjs` moves the listed packages
to `/var/runtime/node_modules/@aws-sdk` and the rest of npm's tree to `@aws-sdk/node_modules`,
as the managed image lays them out. Every package still finds the same copy of each dependency
as in npm's tree. `update.sh` regenerates both files from a newer managed image.

Compared with the managed image at
`public.ecr.aws/lambda/nodejs@sha256:66c547b04b1ec3b0b832816df70d4911d0721b4d29717dd0bd5358876586092e`:

| | Result |
|---|---|
| `@aws-sdk` packages | The same 553 packages at the same versions |
| Their dependencies | npm's tree satisfies every declared version range and the managed tree does not, so 2,014 resolutions of a dependency differ, across 66 dependencies. Most are newer `@smithy` releases: `@smithy/types` 4.19.0 for 4.16.1, `@smithy/core` 3.36.1 for 3.31.1, `@smithy/fetch-http-handler` 5.8.0 for 5.6.13, `@smithy/node-http-handler` 4.12.1 for 4.9.13. The 44 deprecated packages at 3.374.0 get the `@smithy` 1.x releases they declare, where the managed tree gives them its current 2.x, 4.x and 5.x ones |
| Missing dependencies | The managed tree leaves out three declared dependencies: `@aws-sdk/body-checksum-browser` (of `client-glacier`), `@smithy/util-stream-node` (of `@aws-sdk/util-stream-node`) and `@httptoolkit/websocket-stream` (of `aws-crt`). npm installs them, with `ws`, `uuid` and `isomorphic-ws` |
| Overridden packages | The managed image replaces `@aws-sdk/util-utf8-node`, `util-base64-node` and `util-stream-node` with re-exports of their successors ("re-export override from AWS SDK custom build"). This build ships npm's releases of them |
| Files | Every package is as npm publishes it: 114,051 files and 497 MB, against the managed image's 4,489 files and 106 MB, which keeps only `dist-cjs` and a `package.json` cut down to six fields. Where both have a file, it is identical apart from `package.json`, unless the package's version or build differs as above |
| Leftover files | The managed image has 57 files that npm's release of the same version doesn't, such as 16 per-provider files in `@aws-sdk/credential-providers/dist-cjs`. The packages' entry points don't load them |

## Open questions

- **OpenSSL module paths.** The managed `libcrypto` has nonexistent build paths compiled
  in, so `--openssl-legacy-provider` fails in the managed runtime. This build fixes that, which
  changes customer-visible behaviour.
- **Base image.** Reinstalling the base packages is not byte-reproducible, because the rpm
  database records install times. A base built once and pinned by digest, possibly shared with
  other runtimes, would fix this. The `base` section of the Dockerfile is self-contained so it
  can move to its own build; `BASE_IMAGE` then supplies it.
- **`node` is not byte-reproducible across machines.** Node's `configure.py` lists ICU's sources
  in filesystem directory order (`glob_to_var` uses an unsorted `os.walk`), which sets ICU's
  link order. Builds on one machine are identical; builds on different machines can differ.
  Sorting the list would fix it upstream.
- **Release identifier.** `runtime-release` takes its value from the commit timestamp; the
  release process may want a counter instead.
- **amd64** has not been built yet.
