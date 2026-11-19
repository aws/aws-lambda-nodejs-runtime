# Adds the public Runtime Interface Emulator and test functions to a runtime image.
# Build with test/run.mjs.
#
# The managed-runtime entrypoint always runs bootstrap, so RIE is started explicitly and runs
# /lambda-entrypoint.sh with the handler passed as the container command.

ARG IMAGE
FROM ${IMAGE}
ARG RIE_URL
ARG RIE_SHA256
ADD --checksum=sha256:${RIE_SHA256} --chmod=0755 ${RIE_URL} /usr/local/bin/aws-lambda-rie
COPY handlers/ /var/task/
COPY layer/ /opt/
ENTRYPOINT ["/usr/local/bin/aws-lambda-rie", "/lambda-entrypoint.sh"]
