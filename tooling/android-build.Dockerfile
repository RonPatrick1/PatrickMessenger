FROM ghcr.io/cirruslabs/flutter:stable

ARG ANDROID_NDK_VERSION=28.2.13676358
ENV CARGO_HOME=/opt/cargo
ENV RUSTUP_HOME=/opt/rustup
ENV PATH=/opt/cargo/bin:$PATH

RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager \
        "ndk;${ANDROID_NDK_VERSION}" \
        "cmake;3.22.1" \
        "build-tools;35.0.0" \
        "platforms;android-31" \
        "platforms;android-34" \
        "platforms;android-35"

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
        https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal \
    && rustup target add \
        aarch64-linux-android \
        armv7-linux-androideabi \
        i686-linux-android \
        x86_64-linux-android \
    && chmod -R a+rwX "$CARGO_HOME" "$RUSTUP_HOME"

WORKDIR /app

CMD ["flutter", "build", "apk", "--debug"]
