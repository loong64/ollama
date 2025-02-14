FROM ghcr.io/loong64/debian:trixie-slim

RUN apt-get update && \
    apt-get install -y ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG VERSION

RUN curl -L https://github.com/loong64/ollama/releases/download/${VERSION}/ollama-linux-loong64.tgz | tar -xz

ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]