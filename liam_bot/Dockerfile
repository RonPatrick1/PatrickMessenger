FROM rust:1.93-bookworm AS build

WORKDIR /src
COPY liam_bot/Cargo.toml liam_bot/Cargo.lock* ./
COPY liam_bot/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 liam
COPY --from=build /src/target/release/patrick-messenger-liam /usr/local/bin/liam

USER liam
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/liam"]
