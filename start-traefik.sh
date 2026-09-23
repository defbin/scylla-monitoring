#!/usr/bin/env bash
#
# Starts the traefik mTLS reverse proxy in front of the monitoring stack.
# The version comes from TRAEFIK_VERSION in versions.sh, the same value
# fetch_traefik_image.sh bakes into the image, so the proxy that runs is the
# one the image ships.
#
# input (env): PRIVATE_IP CERT_DIR (holding server.crt server.key rootCA.crt)
# optional (env): TAG overrides TRAEFIK_VERSION

cd "$(dirname "$0")" || exit 1
# shellcheck source=versions.sh
. versions.sh
set -euo pipefail

die() { echo "$@" >&2; exit 1; }

REQUIRED=(PRIVATE_IP CERT_DIR)
for VAR in "${REQUIRED[@]}"; do
	export "$VAR"="${!VAR:-}"; [[ -z "${!VAR}" ]] && die "error: $VAR is required"
done

export TAG="${TAG:-$TRAEFIK_VERSION}"
IMG="traefik:${TAG}"

cat > /home/centos/traefik.yml <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false
# log process events to stdout
log:
  filePath: ""
  level: INFO
# log traffic to stdout
accessLog:
  filePath: ""
entryPoints:
  agraf:
    address: "${PRIVATE_IP}:3000"
  aprom:
    address: "${PRIVATE_IP}:9090"
  aalert:
    address: "${PRIVATE_IP}:9093"
  node-exporter:
    address: "${PRIVATE_IP}:9100"
  sidecar1:
    address: "${PRIVATE_IP}:10911"
  ping:
    address: "localhost:8080"
providers:
  file:
    directory: "/etc/traefik/confs"

# Uncomment to access the traefik dashboard at :8080
#api:
#  insecure: true

# enable healthcheck endpoint
ping:
  entryPoint: "ping"
EOF

cat > /home/centos/traefik-conf.yml <<EOF
http:
  routers:
    to-agraf:
      tls: true
      entryPoints:
        - agraf
      rule: "PathPrefix(\`/\`)"
      service: "agraf"
    to-aprom:
      tls: true
      entryPoints:
        - aprom
      rule: "PathPrefix(\`/\`)"
      service: "aprom"
    to-aalert:
      tls: true
      entryPoints:
        - aalert
      rule: "PathPrefix(\`/\`)"
      service: "aalert"
    to-node-exporter:
      tls: true
      entryPoints:
        - node-exporter
      rule: "PathPrefix(\`/\`)"
      service: "node-exporter"
    to-sidecar1:
      tls: true
      entryPoints:
        - sidecar1
      rule: "PathPrefix(\`/\`)"
      service: "sidecar1"
  services:
    agraf:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:3000"
    aprom:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9090"
    aalert:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9093"
    node-exporter:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9100"
    sidecar1:
      loadBalancer:
        servers:
          - url: "h2c://127.0.0.1:10911"
tls:
  options:
    default:
      clientAuth:
        caFiles:
          - /etc/traefik/rootCA.crt
        clientAuthType: RequireAndVerifyClientCert
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/server.crt
        keyFile: /etc/traefik/server.key
EOF

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
	./fetch_traefik_image.sh || die "failed: could not pull $IMG from any registry"
fi

docker rm --force traefik || true

docker run -d --name traefik \
	--network="host" \
	--restart unless-stopped \
	--log-opt mode=non-blocking \
	-v /home/centos/traefik.yml:/etc/traefik/traefik.yml \
	-v /home/centos/traefik-conf.yml:/etc/traefik/confs/traefik-conf.yml \
	-v "${CERT_DIR}/server.crt:/etc/traefik/server.crt" \
	-v "${CERT_DIR}/server.key:/etc/traefik/server.key" \
	-v "${CERT_DIR}/rootCA.crt:/etc/traefik/rootCA.crt" \
	-v /var/run/docker.sock:/var/run/docker.sock \
	"$IMG"

# A bare `docker run -d` returns as soon as the container is created, before
# traefik has opened its listeners and loaded the file-provider routers. During
# that window requests are refused (000) or answered with 404 (no router yet).
# Wait until traefik actually routes a request. We classify by HTTP status code:
# any routed response (200/502/503/...) means traefik is ready, even if the
# target service is still down.
unset http_proxy
unset https_proxy

wait_for_traefik_ready() {
	local url="https://${PRIVATE_IP}:9090/-/healthy"
	local deadline=$((SECONDS + 60))
	local code=""
	while ((SECONDS < deadline)); do
		code=$(sudo curl \
			--cacert "${CERT_DIR}/rootCA.crt" \
			--cert "${CERT_DIR}/server.crt" --key "${CERT_DIR}/server.key" \
			--silent --output /dev/null --connect-timeout 5 \
			--write-out '%{http_code}' "$url" 2>/dev/null || true)
		case "$code" in
		000 | 404) ;; # not listening yet / routers not loaded; keep waiting
		*) return 0 ;; # any routed response means traefik is ready
		esac
		sleep 2
	done
	die "error: traefik did not become ready in time (last status: ${code:-none})"
}

wait_for_traefik_ready
