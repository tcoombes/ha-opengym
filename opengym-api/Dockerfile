# openGym API, wrapped as a Home Assistant local add-on.
#
# The upstream images are multi-arch (linux/amd64 + linux/arm64), so this
# resolves correctly on a Pi 5 running 64-bit HAOS with no extra work.
#
# Bump the tag here AND the `version:` in config.yaml when you update, then
# rebuild the add-on so Supervisor pulls the new base layer.
FROM registry.gitlab.com/duartesantos8/opengym/api:1.3.8

COPY run.sh /run.sh
COPY mcp-export.mjs /mcp-export.mjs
RUN chmod a+x /run.sh

# We deliberately do NOT set CMD, so whatever CMD the upstream image declares
# is inherited and passed to run.sh as "$@".
ENTRYPOINT ["/run.sh"]
