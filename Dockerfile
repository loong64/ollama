FROM ghcr.io/loong64/debian:trixie-slim

RUN apt-get update && \
    apt-get install -y ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG VERSION

RUN curl -L https://github.com/loong64/ollama/releases/download/${VERSION}/ollama-linux-loong64.tgz | tar -xz

EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]