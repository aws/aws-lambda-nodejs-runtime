FROM scratch
ARG ARCH=unknown
LABEL org.opencontainers.image.architecture=$ARCH
COPY hello.txt /hello.txt
