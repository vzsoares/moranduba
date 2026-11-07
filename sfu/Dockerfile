FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=0.1.0
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/moranduba-sfu . \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/moranduba-sfu /usr/local/bin/moranduba-sfu
COPY --from=build --chown=65532:65532 /out/data /data
ENV DATA_DIR=/data
VOLUME /data
# Run with --network host: TURN (udp 3478) and media (udp 50000-50200) bind directly.
ENTRYPOINT ["/usr/local/bin/moranduba-sfu"]
