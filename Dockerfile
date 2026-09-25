#
# Zabbix MCP Server
# Copyright (C) 2026 initMAX s.r.o.
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

# NCP: built on the shared hardened NCP base (deploy-ones/dockerfiles/
# ncp-python-base-312-alpine) instead of the pinned, stale python:3.13.5-slim
# (Debian bookworm) image. Every dependency ships a musllinux wheel; WeasyPrint's
# native libs come from Alpine's pango package.
ARG PYTHON_BASE=avizdock/ncp-python-base-312-alpine:latest
# Runtime stage: plain upstream python:3.12-alpine -- the same Alpine release and
# CPython the shared base is built FROM, but without its build toolchain, so the
# image does not carry ~450 MB of gcc/binutils/git layers underneath. Override
# with a lean shared runtime base once deploy-ones provides one.
ARG PYTHON_RUNTIME_BASE=python:3.12-alpine

FROM ${PYTHON_BASE} AS builder

WORKDIR /build
COPY . .
RUN python -m venv /opt/zabbix-mcp/venv \
    && /opt/zabbix-mcp/venv/bin/pip install --no-cache-dir --quiet ".[reporting]" \
    && /opt/zabbix-mcp/venv/bin/pip uninstall -y --quiet pip setuptools wheel

FROM ${PYTHON_RUNTIME_BASE}

LABEL maintainer="initMAX s.r.o. <info@initmax.com>"
LABEL org.opencontainers.image.title="Zabbix MCP Server"
LABEL org.opencontainers.image.description="MCP server for the complete Zabbix API"
LABEL org.opencontainers.image.source="https://github.com/initMAX/zabbix-mcp-server"
LABEL org.opencontainers.image.url="https://github.com/initMAX/zabbix-mcp-server"
LABEL org.opencontainers.image.documentation="https://github.com/initMAX/zabbix-mcp-server/blob/main/README.md"
LABEL org.opencontainers.image.vendor="initMAX s.r.o."
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.version="1.25"

# Drop any build toolchain (present only if PYTHON_RUNTIME_BASE is overridden with
# the shared base) and pip/setuptools/wheel (not needed at runtime; binutils and
# pip's vendored msgpack/setuptools are flagged HIGH), then
# add the system libs for weasyprint PDF rendering (pango pulls in harfbuzz and
# fontconfig; DejaVu matches the fonts the Debian image shipped).
RUN pkgs="$(apk info -e build-base libffi-dev openssl-dev git curl || true)" \
    && if [ -n "$pkgs" ]; then apk del --no-cache $pkgs; fi \
    && apk upgrade --no-cache \
    && apk add --no-cache pango font-dejavu \
    && fc-cache -f \
    && (python -m pip uninstall -y setuptools wheel pip || true)

RUN addgroup -S zabbix-mcp \
    && adduser -S -D -H -G zabbix-mcp -s /sbin/nologin -h /opt/zabbix-mcp zabbix-mcp \
    && mkdir -p /var/log/zabbix-mcp /etc/zabbix-mcp \
    && mkdir -p /etc/zabbix-mcp/assets /etc/zabbix-mcp/tls /etc/zabbix-mcp/templates \
    && chown zabbix-mcp:zabbix-mcp /var/log/zabbix-mcp /etc/zabbix-mcp \
    && chown zabbix-mcp:zabbix-mcp /etc/zabbix-mcp/assets /etc/zabbix-mcp/tls /etc/zabbix-mcp/templates \
    && chmod 750 /etc/zabbix-mcp/tls /etc/zabbix-mcp/templates

COPY --from=builder /opt/zabbix-mcp/venv /opt/zabbix-mcp/venv

ENV PATH="/opt/zabbix-mcp/venv/bin:$PATH"

USER zabbix-mcp
EXPOSE 8080
EXPOSE 9090

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"]

ENTRYPOINT ["/opt/zabbix-mcp/venv/bin/zabbix-mcp-server"]
CMD ["--config", "/etc/zabbix-mcp/config.toml"]
