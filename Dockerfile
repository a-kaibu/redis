FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redis
COPY . .
RUN make -j$(nproc)

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redis
COPY --from=builder /redis/src/redis-server /redis/src/redis-cli /usr/local/bin/

EXPOSE 6379
CMD ["redis-server", "--protected-mode", "no"]
