FROM rust@sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382

ARG GST_PLUGINS_RS_REV=a84bbc66f30573b62871db163c48afef75adf6ec

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg=7:5.1.9-0+deb12u1 \
        gstreamer1.0-plugins-base=1.22.0-3+deb12u6 \
        gstreamer1.0-plugins-bad=1.22.0-4+deb12u7 \
        gstreamer1.0-plugins-good=1.22.0-5+deb12u3 \
        gstreamer1.0-tools=1.22.0-2+deb12u1 \
        iproute2=6.1.0-3 \
        libgstreamer-plugins-base1.0-dev=1.22.0-3+deb12u6 \
        libgstreamer1.0-dev=1.22.0-2+deb12u1 \
        pkg-config=1.8.1-1 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --quiet --filter=blob:none --no-checkout \
        https://github.com/GStreamer/gst-plugins-rs.git /tmp/gst-plugins-rs \
    && git -C /tmp/gst-plugins-rs checkout --quiet "${GST_PLUGINS_RS_REV}" \
    && cargo build \
        --locked \
        --release \
        --manifest-path /tmp/gst-plugins-rs/Cargo.toml \
        -p gst-plugin-fmp4 \
    && install -m 0755 \
        /tmp/gst-plugins-rs/target/release/libgstfmp4.so \
        /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstfmp4.so \
    && rm -rf /tmp/gst-plugins-rs

WORKDIR /workspace
