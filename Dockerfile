# Builds the Lambda Node.js runtime image for one Node major, in four parts:
#   base       the managed-runtime base OS, independent of the runtime language
#   lang       /var/lang: GCC, OpenSSL, and Node from pinned upstream sources
#   runtime    /var/runtime and /lambda-entrypoint.sh: bootstrap, TLS profiles, SDK, RIC
#   image      the runtime image: base, then the managed image's layers in its order
# Build with build.sh, which passes the pinned inputs from base/base.env, builder-images.env,
# runtimes/<major>/lang.env, and runtimes/<major>/versions.env.
#
# Targets:
#   base             the base OS image
#   lang             /var/lang on a clean AL2023 base
#   mainline         the standard runtime (scratch image)
#   durablefunction  the DurableFunction variant: mainline plus @aws/durable-execution-sdk-js,
#                    used only for durable functions
#   image-mainline         the runtime image for the standard runtime
#   image-durablefunction  the runtime image for the DurableFunction variant
# The names follow Lambda's variant names. A mainline build skips the DurableFunction stages.
#
# Build contexts:
#   (main)       the repository root
#   base-src     base/: inputs shared by every runtime
#   lang         optional, a prebuilt lang image (oci-layout:// or docker-image://): replaces
#                the lang stage, so stages that need /var/lang use it instead of compiling it
#   base         optional, docker-image://<base image>: replaces the base stage
# build.sh builds lang on its own first and passes it as the lang context, an OCI layout pinned
# by digest, so /var/lang keeps its own SOURCE_DATE_EPOCH, which changes only with its inputs.
#
# /var/runtime/node_modules/@aws-sdk is installed with npm ci from runtimes/<major>/sdk: the SDK
# packages the managed runtime ships, at its versions, with npm resolving their dependencies.
#
# runtime-release carries a release identifier derived from SOURCE_DATE_EPOCH, normally the
# commit timestamp, so every architecture built from one commit gets the same value.

ARG BASE_MINIMAL
ARG BUILDER_BASE
ARG GCC_BUILDER_BASE

# ---------------------------------------------------------------------------------------------
# Base: shared by every runtime. Uses only BASE_MINIMAL (base/base.env), so it can move to its own
# Dockerfile and be passed back as the base context.
#
# The managed-runtime base reproduced from public amazonlinux:2023-minimal: the managed base adds
# glibc-langpack-en and openssl, and has openssl-snapsafe-libs in place of openssl-libs. Packages
# come from the minimal image's own Amazon Linux release.
# ---------------------------------------------------------------------------------------------

FROM ${BASE_MINIMAL} AS base
RUN microdnf -y swap openssl-libs openssl-snapsafe-libs \
    && microdnf -y install glibc-langpack-en openssl \
    && microdnf clean all \
    && rm -rf /var/cache/dnf

# ---------------------------------------------------------------------------------------------
# /var/lang: Node, OpenSSL, and libstdc++ from upstream sources.
# ---------------------------------------------------------------------------------------------

# Node's configure needs a newer Python than AL2023's python3, and its Temporal support is built
# with Rust from the crates vendored in the Node tarball. python3 is pointed at python3.14 last,
# because dnf runs on the system Python.
FROM ${BUILDER_BASE} AS builder-base
RUN dnf install -y -q \
        tar gzip xz bzip2 make binutils gcc gcc-c++ libstdc++-static python3.14 rust cargo procps-ng \
        patch diffutils flex hardlink findutils perl perl-IPC-Cmd perl-FindBin \
        perl-File-Compare perl-File-Copy perl-Time-Piece \
    && dnf clean all -q \
    && rm -rf /var/cache/dnf \
    && ln -sf /usr/bin/python3.14 /usr/bin/python3

# GCC is built from source because AL2023's default GCC 11 is older than Node 26 supports,
# and the current runtime ships GCC 13.2.0's libstdc++. The recipe is the managed runtime's,
# built in place on the AL2023 release current when the managed runtime built its GCC
# (GCC_BUILDER_BASE), with the same packages and configure options. The source is the signed GNU
# release tarball, which contains every file of the GitHub tag archive the recipe downloads, byte
# for byte; it is unpacked into the directory name the recipe builds in.
# This reproduces the shipped libstdc++.so.6.0.32 byte for byte.
FROM ${GCC_BUILDER_BASE} AS gcc
ARG GCC_VERSION
ARG GCC_SHA256
RUN yum install -d1 -y \
        tar gzip xz grep python3 make binutils gcc gcc-c++ libstdc++-static procps patch \
        diffutils jq flex bzip2 \
    && yum clean all -q \
    && rm -rf /var/cache/yum
# download_prerequisites fetches GMP, MPFR, MPC, and ISL and checks them against
# contrib/prerequisites.sha512. Its base URL is plain HTTP; the same files are served over HTTPS.
RUN mkdir -p /tmp/gcc13-build && cd /tmp/gcc13-build \
    && curl -fsSL -o gcc.tar.xz "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" \
    && echo "${GCC_SHA256}  gcc.tar.xz" | sha256sum -c - \
    && mkdir "gcc-releases-gcc-${GCC_VERSION}" \
    && tar xJf gcc.tar.xz -C "gcc-releases-gcc-${GCC_VERSION}" --strip-components 1 && rm gcc.tar.xz \
    && cd "gcc-releases-gcc-${GCC_VERSION}" \
    && sed -i "s|^base_url='http://|base_url='https://|" contrib/download_prerequisites \
    && grep -q "^base_url='https://gcc.gnu.org/" contrib/download_prerequisites \
    && contrib/download_prerequisites \
    && ./configure -v --prefix=/usr/local/gcc-13 --enable-checking=release \
        --enable-languages=c,c++ --program-prefix=gcc13- --disable-multilib \
    && make -j "$(nproc)" \
    && make install-strip \
    && rm -rf /tmp/gcc13-build

FROM builder-base AS toolchain
COPY --from=gcc /usr/local/gcc-13 /usr/local/gcc-13
RUN ln -sf /usr/local/gcc-13/bin/gcc13-g++ /usr/bin/g++ \
    && ln -sf /usr/local/gcc-13/bin/gcc13-gcc /usr/bin/gcc \
    && ln -sf /usr/local/gcc-13/bin/gcc13-gcc /usr/bin/cc \
    && ln -sf /usr/local/gcc-13/bin/gcc13-g++ /usr/bin/cxx \
    && ln -sf /usr/local/gcc-13/bin/gcc13-g++ /usr/bin/c++ \
    && gcc --version | head -1

# OpenSSL is installed with prefix /var/lang so its compiled-in module and engine
# directories resolve inside the runtime.
FROM toolchain AS openssl
ARG OPENSSL_VERSION
ARG OPENSSL_SHA256
ARG OPENSSL_CONFIGURE_OPTS
RUN curl -fsSL -o /tmp/openssl.tar.gz \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    && echo "${OPENSSL_SHA256}  /tmp/openssl.tar.gz" | sha256sum -c - \
    && mkdir /tmp/openssl-src \
    && tar xzf /tmp/openssl.tar.gz -C /tmp/openssl-src --strip-components 1
WORKDIR /tmp/openssl-src
# libcrypto embeds a "built on" date, which mkbuildinf.pl takes from SOURCE_DATE_EPOCH. The
# release's own VERSION.dat timestamp keeps it fixed for a given OpenSSL version.
RUN ./Configure --prefix=/var/lang --libdir=lib shared ${OPENSSL_CONFIGURE_OPTS} \
    && SOURCE_DATE_EPOCH=$(stat -c %Y VERSION.dat) make -j "$(nproc)" \
    && make install_sw DESTDIR=/tmp/openssl-install

FROM builder-base AS node-src
ARG NODE_VERSION
ARG NODE_SHA256
ARG MAJOR_VERSION
RUN curl -fsSL -o /tmp/node.tar.gz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.gz" \
    && echo "${NODE_SHA256}  /tmp/node.tar.gz" | sha256sum -c - \
    && mkdir /src \
    && tar xzf /tmp/node.tar.gz -C /src \
    && rm /tmp/node.tar.gz
COPY runtimes/nodejs${MAJOR_VERSION}.x/patches /tmp/patches
WORKDIR /src/node-v${NODE_VERSION}
RUN for p in /tmp/patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "applying $p" && patch -p1 --dry-run < "$p" && patch -p1 < "$p" || exit 1; \
    done

# Node is built in /src/node-v<version>, as the managed runtime builds it: source paths are
# compiled into the binary, so the directory affects its layout.
FROM toolchain AS node
ARG NODE_CONFIGURE_OPTS
ARG MAJOR_VERSION
ARG NODE_VERSION
COPY --from=openssl /tmp/openssl-install/var/lang /tmp/openssl
COPY --from=node-src /src /src
RUN mkdir -p /var/lang/lib \
    && cp -fv /usr/local/gcc-13/lib64/libstdc++.so* /var/lang/lib/ \
    && rm -f /var/lang/lib/libstdc++.so.6.*.py
ENV LD_LIBRARY_PATH=/var/lang/lib:/tmp/openssl/lib
WORKDIR /src/node-v${NODE_VERSION}
RUN CC=/usr/bin/cc CXX=/usr/bin/c++ AR=gcc-ar ./configure --verbose --prefix=/var/lang \
        --shared-openssl --shared-openssl-libpath=/tmp/openssl/lib \
        --shared-openssl-includes=/tmp/openssl/include ${NODE_CONFIGURE_OPTS}
RUN make -j "$(nproc)" install \
        CFLAGS="-fPIE -fstack-protector-all" \
        CXXFLAGS="-fPIE -fstack-protector-all" \
        LDFLAGS="-pie -z relro -z now -z noexecstack -Wl,-rpath=/var/lang/lib"
# Copies OpenSSL shared objects as regular files and merges identical files into hard
# links, as the managed runtime's build does; the managed images contain no hard links.
# padlock.so, the engine for VIA x86 CPUs, is not shipped on either architecture.
RUN rm -rf /tmp/openssl/lib/pkgconfig \
    && find /tmp/openssl/lib -name '*.a' -delete \
    && rm -f /tmp/openssl/lib/engines-3/padlock.so \
    && cp -rL /tmp/openssl/lib/. /var/lang/lib/ \
    && hardlink -c /var/lang/lib
COPY runtimes/nodejs${MAJOR_VERSION}.x/locks /tmp/locks
RUN /var/lang/bin/node -e 'require("fs").writeFileSync(1, JSON.stringify([...require("tls").rootCertificates].sort(), null, 2) + "\n")' > /tmp/root-ca-certs.lock \
    && diff /tmp/locks/root-ca-certs.lock /tmp/root-ca-certs.lock \
    && /var/lang/bin/node -e 'require("fs").writeFileSync(1, JSON.stringify(Object.getOwnPropertyNames(globalThis).sort(), null, 2) + "\n")' > /tmp/globals.lock \
    && diff /tmp/locks/globals.lock /tmp/globals.lock

# /var/lang on a clean base, for contract capture.
FROM ${BUILDER_BASE} AS lang
COPY --from=node /var/lang /var/lang

# ---------------------------------------------------------------------------------------------
# /var/runtime and /lambda-entrypoint.sh. Stages that need Node and npm, as build tools or as the
# headers the RIC addon compiles against, copy /var/lang from the lang stage.
# ---------------------------------------------------------------------------------------------

# npm installs from the public registry unless build.sh passes an npmrc secret, which is mounted
# as ~/.npmrc for the npm ci steps only and is not stored in any layer.
#
# The SDK is installed with npm ci from the per-major package.json and package-lock.json, with
# install scripts disabled, then moved into the managed layout: the listed @aws-sdk packages in
# @aws-sdk, and the rest of npm's tree under @aws-sdk/node_modules. layout.mjs moves the packages
# by rename, which works only within one layer, so it runs in the same step as npm ci.
FROM ${BUILDER_BASE} AS sdk
ARG MAJOR_VERSION
COPY --from=lang /var/lang /var/lang
ENV PATH=/var/lang/bin:$PATH
WORKDIR /sdk
COPY runtimes/nodejs${MAJOR_VERSION}.x/sdk/package.json runtimes/nodejs${MAJOR_VERSION}.x/sdk/package-lock.json runtimes/nodejs${MAJOR_VERSION}.x/sdk/layout.mjs ./
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci --ignore-scripts --no-audit --no-fund \
    && node layout.mjs /sdk /sdk/out

# The RIC is installed with npm ci from the per-major package.json and package-lock.json, which
# pin it and the build tools for its addon by version and integrity, with install scripts
# disabled; only the pinned package ships. Its native
# addon is then built explicitly: preinstall.sh compiles the bundled curl and aws-lambda-cpp
# sources, and postinstall.sh runs node-gyp against the runtime's own Node headers.
FROM ${BUILDER_BASE} AS ric
ARG MAJOR_VERSION
RUN dnf install -y -q cmake make gcc gcc-c++ python3 tar xz findutils \
    && dnf clean all -q && rm -rf /var/cache/dnf
COPY --from=lang /var/lang /var/lang
ENV PATH=/var/lang/bin:$PATH \
    npm_config_nodedir=/var/lang
WORKDIR /ric
COPY runtimes/nodejs${MAJOR_VERSION}.x/ric/package.json runtimes/nodejs${MAJOR_VERSION}.x/ric/package-lock.json ./
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci --ignore-scripts --no-audit --no-fund
WORKDIR /ric/node_modules/aws-lambda-ric
RUN sh scripts/preinstall.sh && sh scripts/postinstall.sh \
    && test -f rapid-client.node

# File modes are set explicitly rather than inherited from the checkout. install creates
# missing parent directories with mode 0755.
FROM ${BUILDER_BASE} AS assemble
ARG MAJOR_VERSION
ARG NODE_VERSION
ARG SOURCE_DATE_EPOCH
COPY runtimes/nodejs${MAJOR_VERSION}.x/bootstrap runtimes/nodejs${MAJOR_VERSION}.x/resolve-tls-profile.sh \
    runtimes/nodejs${MAJOR_VERSION}.x/ca-cert.pem runtimes/nodejs${MAJOR_VERSION}.x/THIRD-PARTY-LICENSES.txt \
    /src/runtime/
COPY runtimes/nodejs${MAJOR_VERSION}.x/tls-profiles /src/runtime/tls-profiles
COPY --from=base-src lambda-entrypoint.sh /src/lambda-entrypoint.sh
RUN install -D -m 0755 /src/runtime/bootstrap /out/var/runtime/bootstrap \
    && install -D -m 0755 /src/runtime/resolve-tls-profile.sh /out/var/runtime/resolve-tls-profile.sh \
    && install -D -m 0644 -t /out/var/runtime/tls-profiles /src/runtime/tls-profiles/* \
    && install -D -m 0644 /src/runtime/ca-cert.pem /out/var/runtime/ca-cert.pem \
    && install -D -m 0644 /src/runtime/THIRD-PARTY-LICENSES.txt /out/var/runtime/THIRD-PARTY-LICENSES.txt \
    && install -D -m 0755 /src/lambda-entrypoint.sh /out/lambda-entrypoint.sh \
    && test -n "${SOURCE_DATE_EPOCH}" \
    && printf 'NAME=Node.js\nVERSION=%s-%x\nLOGGING=amzn-stdout-tlv\n\n' \
        "${NODE_VERSION}" "${SOURCE_DATE_EPOCH}" > /tmp/runtime-release \
    && install -D -m 0644 /tmp/runtime-release /out/var/runtime/runtime-release
COPY --from=ric /ric/node_modules/aws-lambda-ric/index.mjs /ric/node_modules/aws-lambda-ric/rapid-client.node /tmp/ric/
RUN install -D -m 0644 /tmp/ric/index.mjs /out/var/runtime/index.mjs \
    && install -D -m 0755 /tmp/ric/rapid-client.node /out/var/runtime/rapid-client.node
COPY --from=sdk /sdk/out/@aws-sdk /out/var/runtime/node_modules/@aws-sdk

FROM scratch AS mainline
COPY --from=assemble /out/ /

# The DurableFunction variant adds @aws/durable-execution-sdk-js, installed with npm ci from the
# per-major package.json and package-lock.json. Only that package is copied: its one
# dependency, @aws-sdk/client-lambda, resolves from the runtime's SDK tree.
FROM ${BUILDER_BASE} AS durable-function-sdk
ARG MAJOR_VERSION
COPY --from=lang /var/lang /var/lang
ENV PATH=/var/lang/bin:$PATH
WORKDIR /durable
COPY runtimes/nodejs${MAJOR_VERSION}.x/durable/package.json runtimes/nodejs${MAJOR_VERSION}.x/durable/package-lock.json ./
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci --ignore-scripts --no-audit --no-fund

# Its first layer is mainline's, so the variant is mainline plus one layer.
FROM scratch AS durablefunction
COPY --from=assemble /out/ /
COPY --from=durable-function-sdk /durable/node_modules/@aws/durable-execution-sdk-js /var/runtime/node_modules/@aws/durable-execution-sdk-js

# ---------------------------------------------------------------------------------------------
# The runtime image, in the layer order of the managed runtime image: base OS,
# /THIRD-PARTY-LICENSES.txt, /lambda-entrypoint.sh, /var/lang, /var/runtime. Each variant is its
# own target, so the variant is never an image name.
# ---------------------------------------------------------------------------------------------

# The layers and configuration the variants share. The license file and the entrypoint are the
# same in both.
FROM base AS image-common
COPY --from=mainline /var/runtime/THIRD-PARTY-LICENSES.txt /THIRD-PARTY-LICENSES.txt
COPY --from=mainline /lambda-entrypoint.sh /lambda-entrypoint.sh
COPY --from=lang /var/lang /var/lang

ENV LANG=en_US.UTF-8 \
    TZ=:/etc/localtime \
    PATH=/var/lang/bin:/usr/local/bin:/usr/bin/:/bin:/opt/bin \
    LD_LIBRARY_PATH=/var/lang/lib:/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib:/opt/lib \
    LAMBDA_TASK_ROOT=/var/task \
    LAMBDA_RUNTIME_DIR=/var/runtime

LABEL com.amazonaws.lambda.platform.kernel=k510ga \
      com.amazonaws.lambda.platform.version=sbxv2only

FROM image-common AS image-mainline
COPY --from=mainline /var/runtime /var/runtime
WORKDIR /var/task
ENTRYPOINT ["/lambda-entrypoint.sh"]

FROM image-common AS image-durablefunction
COPY --from=durablefunction /var/runtime /var/runtime
WORKDIR /var/task
ENTRYPOINT ["/lambda-entrypoint.sh"]
