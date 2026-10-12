FROM scratch
ARG ARCH=unknown
LABEL dev.maxday.image.architecture=$ARCH
COPY hello.txt /hello.txt
