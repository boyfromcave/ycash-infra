# The yew/web static bundle behind nginx. Build context = this directory; the bundle comes in as
# the named context `dist` (`make image-web`: --build-context dist=$(YEW)/web/dist, the output of
# `npm run build` in yew/web). nginx.conf is an envsubst template (the image's entrypoint renders
# /etc/nginx/templates/*.template into conf.d): $CSP_CONNECT_SRC_EXTRA widens the CSP's
# connect-src for a dev cluster (the kind smoke's loopback proving-file mirror); empty in
# production, where the bundle, the API and download.z.cash are the only destinations.
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
ENV CSP_CONNECT_SRC_EXTRA="" NGINX_ENVSUBST_FILTER="^CSP_"
COPY --from=dist / /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/templates/default.conf.template
