FROM docker:dind

RUN apk add --no-cache \
        python3 \
        py3-pip \
        py3-virtualenv \
        yq \
    && pip3 install --no-cache-dir --break-system-packages \
        uv