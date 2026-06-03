ARG FLAVOR=${TARGETARCH}
ARG CMAKEVERSION=3.31.2
ARG NINJAVERSION=1.12.1

FROM --platform=linux/loong64 ghcr.io/loong64/anolis:23 AS base-loong64
# install anolis-epao-release for ccache
RUN yum install -y dnf-plugins-core anolis-epao-release \
    && curl -fsSLo /etc/yum.repos.d/anolis-crb.repo https://github.com/loong64/container-images/raw/805ba27783e72d199ce5c8d7d75b7e1119b41e0b/Containerfiles/23/anolis-crb.repo \
    && curl -fsSLo /etc/yum.repos.d/AnolisOS-Devel.repo https://github.com/Loongson-Cloud-Community/docker-library/raw/39dd347e48f476ade13d851188848cfc7f4034f8/openanolis/anolisos/23.4/AnolisOS-Devel.repo \
    && dnf config-manager --set-enabled crb \
    && dnf install -y clang ccache git
ENV CC=clang CXX=clang++

FROM base-${TARGETARCH} AS base
ARG CMAKEVERSION
ARG NINJAVERSION
RUN curl -fsSL https://github.com/loong64/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
RUN dnf install -y unzip \
    && curl -fsSL -o /tmp/ninja.zip https://github.com/loong64/ninja/releases/download/v${NINJAVERSION}/ninja-linux-$(uname -m).zip \
    && unzip /tmp/ninja.zip -d /usr/local/bin \
    && rm /tmp/ninja.zip
ENV CMAKE_GENERATOR=Ninja
ENV LDFLAGS=-s

#
# GPU toolchain stages — provide compilers for llama-server GPU builds
#

FROM base AS cpu-deps
RUN dnf install -y gcc-toolset-14-gcc gcc-toolset-14-gcc-c++
ENV PATH=/opt/rh/gcc-toolset-14/root/usr/bin:$PATH

#
# llama-server stages — rebuild when LLAMA_CPP_VERSION, llama/server/, or llama/compat/ changes.
#
# CPU stage: llama-server + ggml-base + ggml-cpu variants → lib/ollama/
# GPU stages: GPU backend .so only → lib/ollama/<variant>/
#

FROM cpu-deps AS llama-server-cpu
COPY LLAMA_CPP_VERSION .
COPY llama/server llama/server
COPY llama/compat llama/compat
RUN --mount=type=cache,target=/root/.ccache \
    cmake -S llama/server --preset cpu \
        && cmake --build build/llama-server-cpu -- -l $(nproc) \
        && cmake --install build/llama-server-cpu --component llama-server --strip \
        && for lib in \
            /usr/lib64/libgomp.so* \
            /usr/lib64/libomp.so* \
            /opt/rh/gcc-toolset-14/root/usr/lib64/libgomp.so* \
            /opt/rh/gcc-toolset-14/root/usr/lib64/libomp.so*; do \
                [ -e "$lib" ] && cp -a "$lib" dist/lib/ollama/ || true; \
            done

FROM scratch AS publish-llama-server-cpu
COPY --from=llama-server-cpu dist/lib/ollama /lib/ollama/

#
# Go build
#

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
ENV CGO_CFLAGS="${CGO_CFLAGS}"
ENV CGO_CXXFLAGS="${CGO_CXXFLAGS}"
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie -o /bin/ollama .

FROM scratch AS publish-go
COPY --from=build /bin/ollama /bin/ollama

#
# Assembly stages — combine llama-server variants + GPU runtime libs
#

FROM --platform=linux/loong64 scratch AS loong64
COPY --from=llama-server-cpu dist/lib/ollama /lib/ollama/

FROM --platform=linux/loong64 scratch AS loong64-archive
COPY --from=loong64 /lib/ollama /lib/ollama/

FROM ${TARGETARCH}-archive AS archive
COPY --from=build /bin/ollama /bin/ollama

FROM ${FLAVOR} AS image-archive
COPY --from=build /bin/ollama /bin/ollama

FROM ghcr.io/loong64/debian:trixie-slim
RUN apt-get update \
    && apt-get install -y ca-certificates libvulkan1 libopenblas0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
COPY --from=image-archive /bin /usr/bin
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
COPY --from=image-archive /lib/ollama /usr/lib/ollama
ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
