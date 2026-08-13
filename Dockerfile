# syntax=docker/dockerfile:1
#
# ebook2audiobook — reconstructed from build_docker.log (11 build steps) with
# the fixes from this review applied.
#
# ┌─ READ THIS BEFORE OVERWRITING YOUR FILE ──────────────────────────────────┐
# │ A build log only shows instructions that produce a step. ARG defaults,    │
# │ ENV, LABEL, EXPOSE, VOLUME, ENTRYPOINT and CMD are metadata and leave no  │
# │ trace, so they are NOT recoverable from build_docker.log. The blocks      │
# │ marked "KEEP YOUR OWN" below are placeholders — paste your existing lines │
# │ back in. Your run instructions imply at least: EXPOSE 7860 and an         │
# │ ENTRYPOINT on ebook2audiobook.command that forwards --headless/--ebook.   │
# └───────────────────────────────────────────────────────────────────────────┘

FROM python:3.12-slim-bookworm

WORKDIR /app

# ─── KEEP YOUR OWN: ARG defaults ───────────────────────────────────────────
# INSTALL_RUST is referenced by step 3 below. The log shows rustup actually
# running, so it was 1 at build time (default or --build-arg).
ARG INSTALL_RUST=0
# DOCKER_DEVICE carries the detected-hardware JSON into step 7. The log shows
# it already expanded, so the mechanism (ARG vs a generated Dockerfile) isn't
# visible — keep whatever you have and adjust step 7 to match.
ARG DOCKER_DEVICE

# ── 1. system libraries ────────────────────────────────────────────────────
# + libnss3
#     The only library calibre's QtWebEngine needs that nothing else in this
#     list already drags in. ffmpeg/sox/mesa/sdl2 transitively supply
#     libasound2, libxkbcommon0, libgbm1, libdrm2, libglib2.0-0 and the wider
#     libxcb-* set, so this single package is what stands between
#     ebook-convert and a complete install. It pulls libnspr4 and nothing
#     else — libsqlite3-0 and zlib1g are already in the base image — so the
#     cost is roughly 5 MB.
#     Without it: "Failed to import PyQt module: PyQt6.QtWebEngineCore" and
#     PDF *output* dies in pdf_output.py::specialize_options. Ebook -> text
#     conversions never touch QtWebEngine and work either way.
# - --allow-change-held-packages
#     Nothing is held in python:3.12-slim-bookworm. It was a no-op.
# - the second `curl`
#     It appeared twice in the original list.
# + apt-mark manual procps media-types
#     Step 11 purges with --auto-remove, and the cascade otherwise reaps both:
#     procps takes ps/pgrep/top/free out of the runtime image, and media-types
#     takes /etc/mime.types with it, which is what mimetypes.guess_type()
#     reads before falling back to its much smaller built-in table.
#     Marking them manual makes them ineligible for the auto-remove sweep.
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gcc g++ make pkg-config cmake curl wget git bash xz-utils python3-dev \
		fontconfig libfontconfig1 libfreetype6 libgl1 libegl1 libopengl0 \
		libx11-6 libxext6 libxrender1 libxcb1 libxcb-render0 libxcb-shm0 \
		libxcb-xfixes0 libxcb-cursor0 libgomp1 libsndfile1 libnss3 \
		ffmpeg mediainfo nodejs espeak-ng sox tesseract-ocr tesseract-ocr-eng; \
	apt-mark manual procps media-types; \
	rm -rf /var/lib/apt/lists/*

# ── 2. build front-end ─────────────────────────────────────────────────────
# - --ignore-installed
#     It skips the uninstall step, so the new pip is unpacked over the old one
#     and BOTH dist-info directories survive in site-packages. The log showed
#     the symptom plainly: pip downloaded 26.2.1 and then reported
#     "Successfully installed pip-25.0.1", with every later notice still
#     offering the same upgrade.
# + setuptools<82
#     torch 2.11 requires it ("Collecting setuptools<82 (from torch==2.11.0)").
#     Installing 84.0.0 here only to have torch uninstall it and drop to
#     78.1.0 mid-build costs two downloads and an uninstall/reinstall cycle.
#     Note 78.1.0 rather than 81.x: torch resolves through --index-url, which
#     replaces PyPI outright, and that mirror carries no newer <82 wheel.
RUN python3 -m pip install --no-cache-dir --upgrade pip 'setuptools<82' wheel

# ── 3. optional rust toolchain ─────────────────────────────────────────────
# Unchanged. Removed again in step 6 below.
RUN bash -o pipefail -c '\
	if [ "${INSTALL_RUST}" = "1" ]; then \
		curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable; \
	else \
		echo "Skipping Rust toolchain"; \
	fi'

# ── 4. calibre ─────────────────────────────────────────────────────────────
# Unchanged. With libnss3 present the QtWebEngine warning is gone; the
# remaining "FileNotFoundError: 'xdg-icon-resource'" is desktop integration
# the installer attempts in an environment that has no desktop. It is
# cosmetic and does not affect ebook-convert. Adding isolated=y would silence
# it, but that also skips the /usr/bin symlinks and would need
# ENV PATH="/opt/calibre:${PATH}" — not worth it for one log line.
RUN set -eux; \
	wget -nv "https://download.calibre-ebook.com/linux-installer.sh" -O /tmp/calibre.sh; \
	bash /tmp/calibre.sh; \
	rm -f /tmp/calibre.sh

# ── 5. legacy /usr/lib soname shims ────────────────────────────────────────
# Unchanged — left exactly as-is since the consumer of these paths isn't
# visible from the build log.
RUN set -eux; \
	ln -sf /usr/lib/*-linux-gnu/libfreetype.so.6 /usr/lib/libfreetype.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libfontconfig.so.1 /usr/lib/libfontconfig.so.1; \
	ln -sf /usr/lib/*-linux-gnu/libpng16.so.16 /usr/lib/libpng16.so.16; \
	ln -sf /usr/lib/*-linux-gnu/libX11.so.6 /usr/lib/libX11.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libXext.so.6 /usr/lib/libXext.so.6; \
	ln -sf /usr/lib/*-linux-gnu/libXrender.so.1 /usr/lib/libXrender.so.1

# ── 6. application ─────────────────────────────────────────────────────────
COPY . /app

RUN find /app -type f \( -name "*.sh" -o -name "*.command" \) -exec sed -i 's/\r$//' {} \;

# ── 7. install + purge, in ONE layer ───────────────────────────────────────
# This is the merge of the old steps 10 and 11, and it is the single biggest
# change in this file.
#
# A later layer cannot shrink an earlier one. Purging gcc/g++/cmake/git in
# their own RUN only wrote a whiteout entry on top; every byte stayed in the
# image, which is why the build ended with "Total reclaimed space: 0B" and
# "exporting layers 236.8s". Deleting in the same RUN that created the files
# is what actually reclaims the ~466 MB.
#
# Nothing is lost by merging: `COPY . /app` above invalidates this step on any
# source change, so it never came out of cache anyway.
#
# Note the ordering — QT_QPA_PLATFORM is set before the install so any calibre
# probing done during it also runs headless.
ENV QT_QPA_PLATFORM=offscreen

RUN set -eux; \
	./ebook2audiobook.command --script_mode build_docker --docker_device "${DOCKER_DEVICE}"; \
	rustup self uninstall -y 2>/dev/null || true; \
	apt-get update; \
	apt-get purge -y --auto-remove gcc g++ make pkg-config cmake wget git xz-utils python3-dev; \
	rm -rf /var/lib/apt/lists/* /root/.cargo /root/.rustup /tmp/* || true

# ─── KEEP YOUR OWN: runtime metadata ───────────────────────────────────────
# Not recoverable from the build log. Restore your originals here, e.g.:
#
# EXPOSE 7860
# VOLUME ["/app/ebooks", "/app/audiobooks", "/app/models", "/app/voices", "/app/tmp"]
# ENTRYPOINT ["./ebook2audiobook.command"]
#
# If PDF *output* is ever on a conversion path, add this too — the container
# runs as root and Chromium refuses to start that way without --no-sandbox:
#
# ENV QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu --headless --disable-dev-shm-usage"
#
# Do not add --single-process: calibre then fails with
# "Single mode supports only single profile".
