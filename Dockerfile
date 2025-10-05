# Stage 1: Build LightGBM statically on Alpine
FROM alpine:3.22 AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    cmake \
    make \
    g++ \
    gcc \
    libc-dev \
    linux-headers \
    libgomp \
    eigen-dev \
    openblas-dev \
    zlib-dev \
    zlib-static \
    libstdc++ \
    libgcc \
    bash

# Clone LightGBM repository
WORKDIR /build
RUN git clone --recursive https://github.com/microsoft/LightGBM && \
    cd LightGBM && \
    git checkout stable

# Build LightGBM with static linking
WORKDIR /build/LightGBM/build
RUN cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_OPENMP=ON \
    -DUSE_GPU=OFF \
    -DUSE_SWIG=OFF \
    -DUSE_HDFS=OFF \
    -DUSE_R35=OFF \
    -DUSE_TIMETAG=OFF \
    -DBUILD_STATIC_LIB=ON \
    -DBUILD_CLI=OFF \
    -DCMAKE_CXX_FLAGS="-static-libgcc -static-libstdc++ -fopenmp -pthread" \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++ -fopenmp -pthread" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    make -j$(nproc) && \
    make install

# Copy the static library and headers
RUN mkdir -p /lightgbm-static/lib /lightgbm-static/include /lightgbm-static/bin && \
    cp /usr/local/lib/lib_lightgbm.a /lightgbm-static/lib/ && \
    cp -r /usr/local/include/LightGBM /lightgbm-static/include/ && \
    cp /usr/local/bin/lightgbm /lightgbm_static/bin/ || true

# Verify the build configuration
RUN echo "=== LightGBM Build Verification ===" && \
    echo "Library file size:" && \
    ls -lh /lightgbm-static/lib/lib_lightgbm.a && \
    echo "\nChecking for OpenMP symbols:" && \
    nm /lightgbm-static/lib/lib_lightgbm.a | grep -i omp | head -5 || echo "No OpenMP symbols found" && \
    echo "\nChecking for BLAS symbols:" && \
    nm /lightgbm-static/lib/lib_lightgbm.a | grep -i blas | head -5 || echo "No BLAS symbols found"

# Stage 2: Build the dummy application statically in Alpine
FROM alpine:3.22 AS app-builder

# Install build dependencies
RUN apk add --no-cache \
    g++ \
    gcc \
    libc-dev \
    linux-headers \
    libgomp \
    openblas-dev \
    zlib-dev \
    zlib-static \
    libstdc++ \
    libgcc \
    make \
    cmake \
    musl-dev \
    file

# Copy static library and headers from builder
COPY --from=builder /lightgbm-static /usr/local/

# Create the dummy project
WORKDIR /app

# Copy dummy project files
COPY testapp/main.cpp ./

# Build fully static binary using direct compilation
RUN echo "Building static binary..." && \
    g++ -o lightgbm_example \
        main.cpp \
        -I/usr/local/include \
        /usr/local/lib/lib_lightgbm.a \
        -static \
        -static-libgcc \
        -static-libstdc++ \
        -fopenmp \
        -pthread \
        -lz \
        -lm \
        -O3 \
        -D_OPENMP \
        -DNDEBUG && \
    echo "Build complete!" && \
    echo "\n=== Binary Analysis ===" && \
    file lightgbm_example && \
    echo "\nBinary size:" && \
    ls -lh lightgbm_example && \
    echo "\nChecking for dynamic dependencies:" && \
    ldd lightgbm_example 2>/dev/null || echo "No dynamic dependencies (fully static)" && \
    echo "\n=== Testing Binary ===" && \
    ./lightgbm_example

# Stage 3: Minimal runtime image with static binary
FROM alpine:3.22 AS runtime

# No runtime dependencies needed for static binary!
WORKDIR /app

# Copy only the static binary
COPY --from=app-builder /app/lightgbm_example /app/

# The binary should run without any runtime dependencies
# CMD ["/app/lightgbm_example"]

# Stage 4: Alternative - Debian runtime (optional)
FROM debian:trixie-slim AS debian-runtime

WORKDIR /app

# Copy the static binary built with musl
COPY --from=app-builder /app/lightgbm_example /app/

# Install compatibility layer for musl-built static binaries (if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libc6 && \
    rm -rf /var/lib/apt/lists/* && \
    echo "Testing binary on Debian:" && \
    file /app/lightgbm_example && \
    ldd /app/lightgbm_example 2>/dev/null || echo "No dependencies (static binary)"

# CMD ["/app/lightgbm_example"]
