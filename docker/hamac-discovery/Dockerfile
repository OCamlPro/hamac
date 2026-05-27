# Image runtime pour le discovery server hamac.
#
# Le binaire OCaml est compilé localement par build.sh et copié dans
# l'image. On évite un build OCaml dans Docker pour ne pas avoir à gérer
# l'auth GitLab pour ocamlpro-cli / ocamlpro-codec.
#
# Le binaire ne dépend que de glibc + libm, donc debian-slim suffit.

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="hamac-discovery" \
      org.opencontainers.image.description="Discovery server for hamac provisioning : REST API for node registration and provisioning profiles" \
      org.opencontainers.image.source="https://gitlab.ocamlpro.com/OCamlPro/sieste" \
      org.opencontainers.image.licenses="proprietary" \
      org.opencontainers.image.authors="OCamlPro <contact@ocamlpro.com>" \
      org.opencontainers.image.version="0.1.0"

# ca-certificates : pour les requêtes HTTPS sortantes éventuelles
# tzdata : timestamps dans les logs et records
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# User non-root pour limiter l'impact d'une compromission du process
RUN groupadd -r hamac && useradd -r -g hamac -d /var/lib/hamac-discovery hamac

# Le binaire est copié par build.sh après `dune build`
COPY discovery_server.exe /usr/local/bin/hamac-discovery

# Bundles + profils built-in (catalogue) : copiés par build.sh dans le
# contexte. Servent à rendre les profils au runtime (mode b) et de seed du
# catalogue. Les profils/bundles "custom" vivent dans le state (volume).
COPY bundles  /usr/share/hamac/bundles
COPY profiles /usr/share/hamac/profiles

# State directory persisté via volume Swarm
RUN mkdir -p /var/lib/hamac-discovery/provisioning \
 && chown -R hamac:hamac /var/lib/hamac-discovery
VOLUME ["/var/lib/hamac-discovery"]

ENV HAMAC_DISCOVERY_STATE=/var/lib/hamac-discovery \
    HAMAC_BUNDLES_DIR=/usr/share/hamac/bundles \
    HAMAC_PROFILES_DIR=/usr/share/hamac/profiles \
    PORT=8877

USER hamac
WORKDIR /var/lib/hamac-discovery

EXPOSE 8877

# Healthcheck pour Swarm : /health renvoie 200 quand le serveur tourne
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/bin/curl", "-fsS", "http://localhost:8877/health"]

ENTRYPOINT ["/usr/local/bin/hamac-discovery"]
