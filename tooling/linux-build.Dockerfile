FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        clang \
        cmake \
        curl \
        git \
        libgtk-3-dev \
        liblzma-dev \
        libstdc++-12-dev \
        ninja-build \
        pkg-config \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update \
    && apt-get install -y --no-install-recommends rustup \
    && rm -rf /var/lib/apt/lists/*

RUN git config --system --add safe.directory /opt/flutter \
    && git config --system --add safe.directory /app

USER ubuntu
ENV HOME=/home/ubuntu
ENV PATH=/home/ubuntu/.cargo/bin:/opt/flutter/bin:$PATH

RUN rustup set profile minimal \
    && rustup toolchain install stable \
    && rustup default stable

WORKDIR /app

CMD ["flutter", "build", "linux", "--debug"]
