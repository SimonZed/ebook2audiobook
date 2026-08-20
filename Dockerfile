ARG PYTHON_VERSION=3.12

# ============================================================
# SINGLE STAGE — BUILD + RUNTIME
# ============================================================
# trixie, not bookworm: Intel's NEO/IGC debs are built on Ubuntu 24.04 and need
# glibc >= 2.38 / libstdc++ >= 13.1. bookworm is 2.36 / 12.2 and cannot host them,
# and its Level Zero loader (libze1 1.8.12) predates zesInit.
FROM python:${PYTHON_VERSION}-slim-trixie

ARG APP_VERSION=26.8.20
ARG DEVICE_TAG=cu130
ARG DOCKER_DEVICE_STR='{"name": "cuda", "os": "manylinux_2_28", "arch": "x86_64", "pyvenv": [3, 12], "tag": "cu130", "note": "default device"}'
ARG DOCKER_PROGRAMS_STR="curl ffmpeg mediainfo nodejs npm espeak-ng sox tesseract-ocr"
ARG CALIBRE_INSTALLER_URL="https://download.calibre-ebook.com/linux-installer.sh"
ARG ISO3_LANG=eng
ARG INSTALL_RUST=1

# Intel GPU user-mode stack, only pulled in for the xpu build. Debian trixie has
# the Level Zero loader (libze1 1.20.6, has zesInit) but no intel-compute-runtime
# at all, so the L0 driver comes from Intel's release debs. NEO and IGC must be a
# matched pair — take IGC_TAG/IGC_BUILD from the NEO release page notes.
ARG NEO_VERSION=26.18.38308.1
ARG IGC_TAG=v2.34.4
ARG IGC_BUILD=2.34.4+21428
ARG GMM_VERSION=22.10.0

LABEL org.opencontainers.image.title="ebook2audiobook" \
	org.opencontainers.image.description="Generate audiobooks from e-books, voice cloning & 1158 languages!" \
	org.opencontainers.image.version="${APP_VERSION}" \
	org.opencontainers.image.authors="Drew Thomasson / Rob McDowell" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.source="https://github.com/DrewThomasson/ebook2audiobook"

ENV DEBIAN_FRONTEND=noninteractive \
	PYTHONDONTWRITEBYTECODE=1 \
	PYTHONUNBUFFERED=1 \
	PIP_NO_CACHE_DIR=1 \
	DOCKER_DEVICE_STR=${DOCKER_DEVICE_STR} \
	PIP_BREAK_SYSTEM_PACKAGES=1 \
	PATH="/root/.cargo/bin:${PATH}" \
	IN_DOCKER=1

WORKDIR /app

# Enable Debian contrib, non-free, and non-free-firmware repositories, then install system packages
# NOTE: no Intel packages here — intel-opencl-icd does not exist in trixie, and
# libze1 on its own is a loader with no driver behind it. See the xpu block below.
RUN set -eux; \
	if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
		sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources; \
	else \
		sed -i 's/main/main contrib non-free non-free-firmware/g' /etc/apt/sources.list; \
	fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gcc g++ make pkg-config cmake curl wget git bash xz-utils python3-dev \
		fontconfig libfontconfig1 libfreetype6 libgl1 libegl1 libopengl0 \
		libx11-6 libxext6 libxrender1 libxcb1 libxcb-render0 libxcb-shm0 \
		libxcb-xfixes0 libxcb-cursor0 libgomp1 libsndfile1 libnss3 \
		${DOCKER_PROGRAMS_STR} tesseract-ocr tesseract-ocr-eng; \
	rm -rf /var/lib/apt/lists/*

# Intel XPU user-mode driver — runs only when DEVICE_TAG=xpu.
# libze1        Debian trixie, Level Zero loader 1.20.6 (exports zesInit)
# libze-intel-gpu1  Intel NEO, the actual L0 driver (was intel-level-zero-gpu)
# intel-igc-*   SPIR-V -> ISA JIT the driver calls at first kernel launch
# libigdgmm12   Intel graphics memory manager
# `apt-get install ./x.deb` (not dpkg -i) so Debian resolves libnl/libva/etc.
RUN set -eux; \
	if [ "${DEVICE_TAG}" != "xpu" ]; then \
		echo "DEVICE_TAG='${DEVICE_TAG}' — skipping Intel GPU runtime"; exit 0; \
	fi; \
	mkdir -p /tmp/neo; cd /tmp/neo; \
	curl -fsSLO "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_TAG}/intel-igc-core-2_${IGC_BUILD}_amd64.deb"; \
	curl -fsSLO "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_TAG}/intel-igc-opencl-2_${IGC_BUILD}_amd64.deb"; \
	curl -fsSLO "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/libigdgmm12_${GMM_VERSION}_amd64.deb"; \
	curl -fsSLO "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/libze-intel-gpu1_${NEO_VERSION}-0_amd64.deb"; \
	apt-get update; \
	apt-get install -y --no-install-recommends libze1 ./*.deb; \
	cd /; rm -rf /tmp/neo /var/lib/apt/lists/*; \
	python3 -c "import ctypes; ctypes.CDLL('libze_loader.so.1').zesInit; print('libze_loader: zesInit present')"

RUN python3 -m pip install --no-cache-dir --upgrade pip 'setuptools<82' wheel

# Rust toolchain
RUN set -eux; \
	if [ "${INSTALL_RUST}" = "1" ]; then \
		curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable; \
	else \
		echo "Skipping Rust toolchain"; \
	fi

# Calibre (CLI)
RUN set -eux; \
	wget -nv "${CALIBRE_INSTALLER_URL}" -O /tmp/calibre.sh; \
	bash /tmp/calibre.sh; \
	rm -f /tmp/calibre.sh

# Debian-compatible Calibre library aliases
RUN set -eux; \
	ln -sf /usr/lib/*-linux-gnu/libfreetype.so.6 /usr/lib/libfreetype.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libfontconfig.so.1 /usr/lib/libfontconfig.so.1; \
	ln -sf /usr/lib/*-linux-gnu/libpng16.so.16 /usr/lib/libpng16.so.16; \
	ln -sf /usr/lib/*-linux-gnu/libX11.so.6 /usr/lib/libX11.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libXext.so.6 /usr/lib/libXext.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libXrender.so.1 /usr/lib/libXrender.so.1

COPY . /app

# Ensure Unix line endings
RUN find /app -type f \( -name "*.sh" -o -name "*.command" \) -exec sed -i 's/\r$//' {} \;

ENV QT_QPA_PLATFORM=offscreen

# Build the image and Cleanup build-only packages and Rust toolchain to shrink the image
RUN set -eux; \
	./ebook2audiobook.command --script_mode build_docker --docker_device "${DOCKER_DEVICE_STR}"; \
	rustup self uninstall -y 2>/dev/null || true; \
	apt-get update; \
	apt-get purge -y --auto-remove gcc g++ make pkg-config cmake wget git xz-utils python3-dev; \
	rm -rf /var/lib/apt/lists/* /root/.cargo /root/.rustup /tmp/* || true

VOLUME \
	/app/ebooks \
	/app/audiobooks \
	/app/models \
	/app/voices \
	/app/run \
	/app/tmp

EXPOSE 7860

ENTRYPOINT ["bash", "ebook2audiobook.command", "--script_mode", "full_docker"]
