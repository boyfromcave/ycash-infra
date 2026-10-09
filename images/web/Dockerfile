# The yew/web static bundle behind nginx. Build context = yew/web (its dist/ from `npm run build`).
FROM nginx:1.27-alpine
COPY dist/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
