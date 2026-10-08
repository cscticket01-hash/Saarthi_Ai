FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json exchange.cjs server.cjs ./
USER node
EXPOSE 8080
CMD ["node", "server.cjs"]
