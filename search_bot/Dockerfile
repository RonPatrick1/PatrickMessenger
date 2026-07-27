FROM rust:1.93-bookworm AS build

WORKDIR /src
COPY search_bot/Cargo.toml search_bot/Cargo.lock* ./
COPY search_bot/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10002 search
COPY --from=build /src/target/release/patrick-messenger-search /usr/local/bin/patrick-search

USER search
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/patrick-search"]
