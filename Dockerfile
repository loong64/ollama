ARG FLAVOR=${TARGETARCH}
ARG PARALLEL=8
ARG CMAKEVERSION=3.31.2

FROM --platform=linux/loong64 ghcr.io/loong64/anolis:23 AS base-loong64
# install anolis-epao-release for ccache
RUN yum install -y dnf-plugins-core anolis-epao-release \
    && curl -fsSLo /etc/yum.repos.d/anolis-crb.repo https://github.com/loong64/container-images/raw/805ba27783e72d199ce5c8d7d75b7e1119b41e0b/Containerfiles/23/anolis-crb.repo \
    && dnf config-manager --set-enabled crb \
    && dnf install -y clang ccache
ENV CC=clang CXX=clang++

FROM base-${TARGETARCH} AS base
ARG CMAKEVERSION
RUN curl -fsSL https://github.com/loong64/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
ENV LDFLAGS=-s

FROM base AS cpu
RUN dnf install -y gcc-toolset-14-gcc gcc-toolset-14-gcc-c++
ENV PATH=/opt/rh/gcc-toolset-14/root/usr/bin:$PATH
ARG PARALLEL
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'CPU' \
        && cmake --build --parallel ${PARALLEL} --preset 'CPU' \
        && cmake --install build --component CPU --strip --parallel ${PARALLEL}

FROM base AS build
WORKDIR /go/src/github.com/ollama/ollama
COPY go.mod go.sum .
RUN curl -fsSL https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-$(case $(uname -m) in x86_64) echo amd64 ;; aarch64) echo arm64 ;; loongarch64) echo loong64 ;; esac).tar.gz | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH
RUN go mod download
COPY . .
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
ARG CGO_CFLAGS
ARG CGO_CXXFLAGS
ENV CGO_LDFLAGS="-Wl,-rpath,/usr/lib/ollama -lggml-cpu -lggml-base"
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=from=cpu,source=dist/lib/ollama,target=/usr/local/lib \
    go build -trimpath -buildmode=pie -o /bin/ollama .

FROM --platform=linux/loong64 scratch AS loong64

FROM ${FLAVOR} AS archive
ARG VULKANVERSION
COPY --from=cpu dist/lib/ollama /lib/ollama
COPY --from=build /bin/ollama /bin/ollama

FROM ghcr.io/loong64/debian:trixie-slim
RUN apt-get update \
    && apt-get install -y ca-certificates libvulkan1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
COPY --from=archive /bin /usr/bin
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
COPY --from=archive /lib/ollama /usr/lib/ollama
ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
