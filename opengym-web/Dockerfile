# openGym web frontend, wrapped as a Home Assistant local add-on.
#
# Keep this tag in step with the API add-on - running mismatched api/web
# versions is the fastest way to a confusing bug.
FROM registry.gitlab.com/duartesantos8/opengym/web:1.3.2

# openGym 1.4.1 switched this image to a non-root user (uid 101), so apk needs
# root - and so does run.sh at runtime: it rewrites nginx's config, and writes
# the exercise media into /data, which Supervisor owns as root. Add-ons run as
# root normally, so this puts us back where 1.3.x was.
USER root

# git replaces upstream's separate one-shot `media` compose service: run.sh
# clones the exercise dataset into /data on first start.
RUN apk add --no-cache git

# Running as root means nginx's workers drop to whatever user its config names
# (often `nobody`) rather than 101, which owns the cache dirs in this image.
# Only proxied /api responses are affected, and only large ones, but it's a
# one-line insurance against a confusing 500.
RUN chmod -R a+rwX /var/cache/nginx 2>/dev/null || true

COPY run.sh /run.sh
RUN chmod a+x /run.sh

ENTRYPOINT ["/run.sh"]
