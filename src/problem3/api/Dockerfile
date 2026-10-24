FROM node:20-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src ./src

# Run as the unprivileged user shipped with the official Node image.
USER node

EXPOSE 3000

CMD ["node", "src/index.js"]
