# Toolchain image for a frappe v17 bench.
#
# The upstream `frappe/bench` image ships an older Python and Node than
# frappe's develop branch requires, so we build the toolchain explicitly.
# See docs/LOCAL_SETUP.md for what breaks with the older versions.
FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG PYTHON_VERSION=3.14
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
		git curl ca-certificates xz-utils \
		mariadb-client libmariadb-dev \
		redis-tools \
		python3 python3-dev python3-pip python3-venv \
		pkg-config libffi-dev libssl-dev build-essential \
		wkhtmltopdf \
	&& rm -rf /var/lib/apt/lists/*

# Node: frappe's package.json requires >=24, which noble does not provide.
RUN set -eux; \
	tarball="$(curl -sS "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
		| grep -oE "node-v${NODE_MAJOR}\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz" | head -1)"; \
	curl -sSL -o "/tmp/${tarball}" "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${tarball}"; \
	mkdir -p /usr/local/node; \
	tar -xJf "/tmp/${tarball}" -C /usr/local/node --strip-components=1; \
	rm -f "/tmp/${tarball}"; \
	/usr/local/node/bin/npm install -g yarn
ENV PATH="/usr/local/node/bin:${PATH}"

# Install bench with the same interpreter its entrypoint shebang names,
# otherwise its dependencies are invisible to it at runtime.
RUN /usr/bin/python3 -m pip install --break-system-packages --no-cache-dir frappe-bench

# bench refuses to run as root.
RUN useradd -m -s /bin/bash frappe
USER frappe
WORKDIR /home/frappe

# uv ships prebuilt CPython builds, avoiding a source compile of 3.14.
RUN uv python install ${PYTHON_VERSION}

EXPOSE 8000 9000
CMD ["bash", "/workspace/docker/init.sh"]
