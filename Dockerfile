# Build environment for the car computer image, pinned so a build on a laptop,
# a lab machine and CI all produce the same thing.
#
# It needs no privileges, so this is a plain container with a bind mount.
FROM debian:bookworm-slim

COPY compile_configs/build-deps.txt /tmp/build-deps.txt

# On an aarch64 host the "cross" compiler is just the native one, and Debian
# has no arm64-on-arm64 cross package.
RUN set -eux; \
    apt-get update; \
    sed 's/#.*//' /tmp/build-deps.txt | xargs apt-get install -y --no-install-recommends; \
    if [ "$(dpkg --print-architecture)" = "arm64" ]; then \
        printf '' > /etc/cross-prefix; \
    else \
        apt-get install -y --no-install-recommends crossbuild-essential-arm64; \
        printf 'aarch64-linux-gnu-' > /etc/cross-prefix; \
    fi; \
    rm -rf /var/lib/apt/lists/* /tmp/build-deps.txt

# The bind-mounted tree belongs to the host user, and git refuses to touch a
# repository it thinks someone else owns.
RUN git config --system --add safe.directory '*'

WORKDIR /src
ENTRYPOINT ["/bin/bash", "-c", "export CROSS_COMPILE=$(cat /etc/cross-prefix); exec \"$@\"", "--"]
CMD ["./create-image.sh"]
