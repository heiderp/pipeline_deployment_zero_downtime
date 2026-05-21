FROM node:20-alpine

WORKDIR /app

COPY package.json .
RUN npm install --production

COPY . .

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["node", "src/index.js"]
