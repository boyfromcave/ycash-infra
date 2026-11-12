# The yew/web static bundle behind nginx. Build context = this directory; the bundle comes in as
# the named context `dist` (`make image-web`: --build-context dist=$(YEW)/web/dist, the output of
# `npm run build` in yew/web). nginx.conf is an envsubst template (the image's entrypoint renders
# /etc/nginx/templates/*.template into conf.d): $CSP_CONNECT_SRC_EXTRA widens the CSP's
# connect-src for a dev cluster (the kind smoke's loopback proving-file mirror); empty in
# production, where the bundle and the API (and the proving files, below) are on this origin.
#
# The Sapling proving files (yew/web's default source since the real-stack run WEB-REAL HIGH-2:
# download.z.cash sends no CORS header, so a browser cannot read it; the wallet fetches
# /sapling-params/<file> from its own origin instead). Fetched here at build time from this
# repository's own parameter mirror, the release zcash-params-v1 (bundles/zcash-params: unchanged
# copies of the download.z.cash files), and kept only if each SHA-256 equals the line in
# bundles/zcash-params/SHA256SUMS, which comes in as the named context `zcash-params` (`make
# image-web`: --build-context zcash-params=bundles/zcash-params), the single source of the sums.
# Never in git (51.6 MB). The wallet checks the same pins again in the browser.
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 AS sapling-params
ARG ZCASH_PARAMS_URL=https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1
COPY --from=zcash-params SHA256SUMS /tmp/SHA256SUMS
RUN set -eu; mkdir /sapling-params; cd /sapling-params; \
    grep -E '  sapling-(spend|output)\.params$' /tmp/SHA256SUMS > SHA256SUMS; \
    [ "$(wc -l < SHA256SUMS)" -eq 2 ]; \
    for name in sapling-spend.params sapling-output.params; do \
      wget -q -O "$name" "$ZCASH_PARAMS_URL/$name"; \
    done; \
    sha256sum -c SHA256SUMS; rm SHA256SUMS; \
    chmod 0444 *.params

FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
ENV CSP_CONNECT_SRC_EXTRA="" NGINX_ENVSUBST_FILTER="^CSP_"
COPY --from=dist / /usr/share/nginx/html/
COPY --from=sapling-params /sapling-params/ /usr/share/nginx/html/sapling-params/
COPY nginx.conf /etc/nginx/templates/default.conf.template
# Unprivileged (as nginxinc/nginx-unprivileged): the pid file in /tmp, no `user` directive, and the
# image's nginx user (uid 101) owning what nginx and the entrypoint write. The chart runs it with a
# read-only root filesystem and emptyDirs at /etc/nginx/conf.d, /var/cache/nginx and /tmp.
RUN sed -i -e 's,^pid .*,pid /tmp/nginx.pid;,' -e '/^user /d' /etc/nginx/nginx.conf \
 && chown -R nginx:nginx /var/cache/nginx /etc/nginx/conf.d
USER nginx
