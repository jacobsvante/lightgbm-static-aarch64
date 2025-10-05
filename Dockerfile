# Build stage: Create LightGBM static library
FROM alpine:3.22 AS builder

ARG LIGHTGBM_VERSION=stable

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
    bash

# Clone and build LightGBM
WORKDIR /build
RUN git clone --recursive https://github.com/microsoft/LightGBM && \
    cd LightGBM && \
    git checkout ${LIGHTGBM_VERSION}

WORKDIR /build/LightGBM/build
RUN cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_OPENMP=ON \
    -DUSE_GPU=OFF \
    -DUSE_SWIG=OFF \
    -DUSE_TIMETAG=OFF \
    -DBUILD_STATIC_LIB=ON \
    -DBUILD_CLI=OFF \
    -DCMAKE_CXX_FLAGS="-static-libgcc -static-libstdc++ -fopenmp -pthread" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    make -j$(nproc) && \
    make install

# Verify the build
RUN echo "=== Build Verification ===" && \
    ls -lh /usr/local/lib/lib_lightgbm.a && \
    nm /usr/local/lib/lib_lightgbm.a | grep -i "LGBM_" | head -5 && \
    echo "OpenMP symbols:" && \
    nm /usr/local/lib/lib_lightgbm.a | grep -i omp | head -3 || echo "No OpenMP symbols" && \
    echo "Header files:" && \
    find /usr/local/include/LightGBM -type f -name "*.h" | wc -l && \
    ls -la /usr/local/include/LightGBM/

# Create metadata
RUN echo "LightGBM Static Library Build Info" > /build_info.txt && \
    echo "====================================" >> /build_info.txt && \
    echo "Build Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> /build_info.txt && \
    echo "LightGBM Version: ${LIGHTGBM_VERSION}" >> /build_info.txt && \
    echo "Git SHA: $(cd /build/LightGBM && git rev-parse HEAD)" >> /build_info.txt && \
    echo "Architecture: $(uname -m)" >> /build_info.txt && \
    echo "Alpine Version: 3.22" >> /build_info.txt && \
    echo "GCC Version: $(gcc --version | head -1)" >> /build_info.txt && \
    echo "CMake Version: $(cmake --version | head -1)" >> /build_info.txt && \
    echo "Library Size: $(ls -lh /usr/local/lib/lib_lightgbm.a | awk '{print $5}')" >> /build_info.txt && \
    echo "Features: OpenMP=ON, GPU=OFF, Static=YES" >> /build_info.txt && \
    echo "" >> /build_info.txt && \
    echo "Header Files:" >> /build_info.txt && \
    echo "-------------" >> /build_info.txt && \
    find /usr/local/include/LightGBM -type f -name "*.h" -exec basename {} \; | sort >> /build_info.txt && \
    echo "" >> /build_info.txt && \
    echo "Total: $(find /usr/local/include/LightGBM -type f -name "*.h" | wc -l) header files" >> /build_info.txt

# Stage 2: Build the dummy application statically in Alpine
FROM alpine:3.22 AS testapp-builder

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
COPY --from=builder /usr/local/lib/lib_lightgbm.a /usr/local/lib/
COPY --from=builder /usr/local/include/LightGBM /usr/local/include/LightGBM

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

# Stage 2: Debian tester
FROM debian:trixie-slim AS testapp

WORKDIR /app

# Copy the static binary built with musl
COPY --from=testapp-builder /app/lightgbm_example /app/

# Install compatibility layer for musl-built static binaries (if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libc6 && \
    rm -rf /var/lib/apt/lists/* && \
    echo "Testing binary on Debian:" && \
    file /app/lightgbm_example && \
    ldd /app/lightgbm_example 2>/dev/null || echo "No dependencies (static binary)"

# CMD ["/app/lightgbm_example"]

# Final minimal stage with just the library
FROM busybox:1.36 AS final

# Copy only the static library and headers
COPY --from=builder /usr/local/lib/lib_lightgbm.a /lib/
COPY --from=builder /usr/local/include/LightGBM /include/LightGBM/
COPY --from=builder /build_info.txt /

# Add labels
LABEL org.opencontainers.image.title="LightGBM Static Library for ARM64" \
    org.opencontainers.image.description="Minimal image containing only LightGBM static library (lib_lightgbm.a) built for ARM64 with OpenMP support" \
    org.opencontainers.image.vendor="Jacob Magnusson" \
    org.opencontainers.image.authors="m@jacobian.se" \
    org.opencontainers.image.source="https://github.com/jacobsvante/lightgbm-static-aarch64" \
    org.opencontainers.image.documentation="https://github.com/jacobsvante/lightgbm-static-aarch64/blob/main/README.md" \
    org.opencontainers.image.licenses="MIT"

# Default command to show contents
CMD ["sh", "-c", "echo '=== LightGBM Static Library ==='; cat /build_info.txt; echo; echo '=== Contents ==='; ls -la /lib/lib_lightgbm.a; echo; echo '=== Headers ==='; find /include -type f | head -20"]
