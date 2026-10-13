FROM node:24-alpine
RUN apk add --no-cache su-exec
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
COPY public ./public
COPY scripts/sqlite-backup.mjs ./scripts/sqlite-backup.mjs
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod 755 /app/docker-entrypoint.sh
ENV NODE_ENV=production HOST=0.0.0.0 DATABASE_PATH=/data/debattle.sqlite
EXPOSE 8787
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["node", "src/server.js"]
