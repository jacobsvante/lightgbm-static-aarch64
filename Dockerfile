# Stage 1: Build LightGBM statically on Debian Bookworm
FROM debian:bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    make \
    g++ \
    gcc \
    ca-certificates \
    libomp-dev \
    libeigen3-dev \
    libopenblas-dev \
    zlib1g-dev \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install newer CMake (LightGBM requires CMake 3.28+)
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-linux-$(uname -m).sh && \
    sh cmake-3.30.5-linux-$(uname -m).sh --prefix=/usr/local --skip-license --exclude-subdir && \
    rm cmake-3.30.5-linux-$(uname -m).sh

# Clone LightGBM repository
ARG LIGHTGBM_VERSION=stable
WORKDIR /build
RUN git clone --recursive https://github.com/microsoft/LightGBM && \
    cd LightGBM && \
    git checkout ${LIGHTGBM_VERSION}

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
RUN mkdir -p /lightgbm-static/lib /lightgbm-static/include && \
    cp /usr/local/lib/lib_lightgbm.a /lightgbm-static/lib/ && \
    cp -r /usr/local/include/LightGBM /lightgbm-static/include/

# Verify the build configuration
RUN echo "=== LightGBM Build Verification ===" && \
    echo "Library file size:" && \
    ls -lh /lightgbm-static/lib/lib_lightgbm.a && \
    echo "\nChecking for OpenMP symbols:" && \
    nm /lightgbm-static/lib/lib_lightgbm.a | grep -i omp | head -5 || echo "No OpenMP symbols found" && \
    echo "\nChecking for BLAS symbols:" && \
    nm /lightgbm-static/lib/lib_lightgbm.a | grep -i blas | head -5 || echo "No BLAS symbols found"

# Stage 2: Build the test application statically on Debian Bookworm
FROM debian:bookworm AS app-builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    gfortran \
    make \
    cmake \
    libc6-dev \
    libomp-dev \
    libopenblas-dev \
    libgfortran-12-dev \
    zlib1g-dev \
    file \
    && rm -rf /var/lib/apt/lists/*

# Copy static library and headers from builder
COPY --from=builder /lightgbm-static /usr/local/

# Create the test application
WORKDIR /app

# Copy test application files
COPY testapp/main.cpp ./

# Build binary with static LightGBM library
# We statically link libgcc and libstdc++ but use dynamic linking for system libraries
# This approach works well on Debian/glibc systems
RUN echo "Building binary with static LightGBM..." && \
    g++ -o lightgbm_example \
        main.cpp \
        -I/usr/local/include \
        /usr/local/lib/lib_lightgbm.a \
        -static-libgcc \
        -static-libstdc++ \
        -fopenmp \
        -lopenblas \
        -lgfortran \
        -lpthread \
        -lm \
        -ldl \
        -O3 \
        -D_OPENMP \
        -DNDEBUG && \
    echo "Build complete!" && \
    echo "\n=== Binary Analysis ===" && \
    file lightgbm_example && \
    echo "\nBinary size:" && \
    ls -lh lightgbm_example && \
    echo "\nDynamic dependencies:" && \
    ldd lightgbm_example && \
    echo "\n=== Testing Binary ===" && \
    ./lightgbm_example

# Stage 3: Minimal runtime image
FROM debian:bookworm-slim AS runtime

# Install minimal runtime dependencies
# The binary needs libgomp (OpenMP) and standard C library
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    file \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the binary
COPY --from=app-builder /app/lightgbm_example /app/

# Verify it runs in minimal runtime
RUN echo "Testing binary in minimal runtime:" && \
    file /app/lightgbm_example && \
    echo "\nDynamic dependencies:" && \
    ldd /app/lightgbm_example && \
    echo "\nRunning test:" && \
    /app/lightgbm_example

CMD ["/app/lightgbm_example"]

# Stage 4: Fully static binary build (alternative approach)
FROM debian:bookworm AS static-builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    gfortran \
    make \
    cmake \
    libc6-dev \
    libomp-dev \
    libopenblas-dev \
    libgfortran-12-dev \
    libgomp1 \
    zlib1g-dev \
    file \
    && rm -rf /var/lib/apt/lists/*

# Copy static library and headers from builder
COPY --from=builder /lightgbm-static /usr/local/

# Create the test application
WORKDIR /app

# Copy test application files
COPY testapp/main.cpp ./

# Attempt to build a fully static binary
# Note: On Debian/glibc, fully static linking is challenging due to glibc limitations
# This will link everything statically including glibc which may cause issues with NSS, DNS, etc.
RUN echo "Building fully static binary..." && \
    g++ -o lightgbm_example_static \
        main.cpp \
        -I/usr/local/include \
        /usr/local/lib/lib_lightgbm.a \
        -static \
        -fopenmp \
        -lopenblas \
        -lgfortran \
        -lpthread \
        -lm \
        -ldl \
        -O3 \
        -D_OPENMP \
        -DNDEBUG 2>&1 || (echo "Fully static build not possible on Debian (expected)" && \
    echo "Building mostly-static binary instead..." && \
    g++ -o lightgbm_example_static \
        main.cpp \
        -I/usr/local/include \
        /usr/local/lib/lib_lightgbm.a \
        -static-libgcc \
        -static-libstdc++ \
        -Wl,-Bstatic \
        -lopenblas \
        -lgfortran \
        -Wl,-Bdynamic \
        -fopenmp \
        -lpthread \
        -lm \
        -ldl \
        -O3 \
        -D_OPENMP \
        -DNDEBUG) && \
    echo "\n=== Static Binary Analysis ===" && \
    file lightgbm_example_static && \
    echo "\nBinary size:" && \
    ls -lh lightgbm_example_static && \
    echo "\nDynamic dependencies (fewer is better):" && \
    ldd lightgbm_example_static 2>&1 || echo "Fully static!" && \
    echo "\n=== Testing Static Binary ===" && \
    ./lightgbm_example_static

# Create build info
RUN echo "LightGBM Static Library Build" > /build_info.txt && \
    echo "=============================" >> /build_info.txt && \
    echo "Base: Debian Bookworm" >> /build_info.txt && \
    echo "Library: /lightgbm-static/lib/lib_lightgbm.a" >> /build_info.txt && \
    echo "Headers: /lightgbm-static/include/LightGBM/" >> /build_info.txt && \
    echo "" >> /build_info.txt && \
    echo "Library size:" >> /build_info.txt && \
    ls -lh /lightgbm-static/lib/lib_lightgbm.a >> /build_info.txt && \
    echo "" >> /build_info.txt && \
    echo "Header files:" >> /build_info.txt && \
    find /lightgbm-static/include -name "*.h" >> /build_info.txt

CMD ["cat", "/build_info.txt"]

# Stage 6: Rust static binary verification (optional)
FROM rust:1.90-bookworm AS rust-static-verify

# Install file utility for binary analysis
RUN apt-get update && apt-get install -y --no-install-recommends \
    file \
    && rm -rf /var/lib/apt/lists/*

# Copy static library and headers from builder
COPY --from=builder /lightgbm-static /usr/local/

# Set environment variable for LightGBM library location
ENV LIGHTGBM_LIB_DIR=/usr/local/lib

# Copy the Rust test application
WORKDIR /app
COPY testapp-rs ./

# Build with standard linking first (minimal dependencies)
RUN cargo build --release && \
    echo "\n=== Rust Binary Verification ===" && \
    file target/release/testapp-rs && \
    echo "\nBinary size:" && \
    ls -lh target/release/testapp-rs && \
    echo "\nDynamic dependencies:" && \
    ldd target/release/testapp-rs && \
    echo "\nTesting binary execution:" && \
    target/release/testapp-rs && \
    echo "\n✓ Binary built and tested successfully"

# Stage 7: Minimal runtime for Rust binary
FROM debian:bookworm-slim AS rust-static-runtime

RUN apt-get update && apt-get install -y libgomp1

# Copy the binary
COPY --from=rust-static-verify /app/target/release/testapp-rs /testapp-rs

# Test it runs
RUN /testapp-rs

ENTRYPOINT ["ldd", "/testapp-rs"]

# Stage 5: Minimal image with static library and headers
FROM busybox:1.36 AS static-runtime

# Copy the static library and headers
COPY --from=builder /lightgbm-static /lightgbm-static/
WORKDIR /lightgbm-static
