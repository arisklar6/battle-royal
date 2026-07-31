# Zero Sum — single shared image for game server + bundled baseline player
# (canonical coworld packaging shape: one image, roles differ by manifest run).

FROM --platform=linux/amd64 nimlang/nim:2.2.6 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# deps first (cache layer): exact pins via nimby.lock, upstream's own flow —
# plain `nimble install` of bitworld is broken upstream (empty package)
COPY nimby.lock config.nims zero_sum.nimble ./
RUN nimble install -y nimby && /root/.nimble/bin/nimby sync nimby.lock

COPY src ./src
COPY game ./game
COPY player ./player

RUN mkdir -p /out && \
    nim c -d:release --hints:off --warnings:off -o:/out/zero_sum_server game/server.nim && \
    nim c -d:release --hints:off --warnings:off -o:/out/zero_sum_baseline player/baseline.nim

FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libcurl4 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/zero_sum_server /app/zero_sum_server
COPY --from=build /out/zero_sum_baseline /app/zero_sum_baseline

EXPOSE 8080
CMD ["/app/zero_sum_server"]
