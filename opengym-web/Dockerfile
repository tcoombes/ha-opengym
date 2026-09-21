# openGym web frontend, wrapped as a Home Assistant local add-on.
#
# Keep this tag in step with the API add-on - running mismatched api/web
# versions is the fastest way to a confusing bug.
FROM registry.gitlab.com/duartesantos8/opengym/web:1.3.2

# git replaces upstream's separate one-shot `media` compose service: run.sh
# clones the exercise dataset into /data on first start.
RUN apk add --no-cache git

COPY run.sh /run.sh
RUN chmod a+x /run.sh

ENTRYPOINT ["/run.sh"]
