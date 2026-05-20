# Stage 1: Build the binary
FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod ./
COPY *.go ./

# Disable CGO for static binary
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o server .

# Stage 2: Minimal runtime image
FROM alpine:3.19

# Security best practice: Do not run as root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

WORKDIR /app
COPY --from=builder /app/server .

EXPOSE 8080
CMD ["./server"]
