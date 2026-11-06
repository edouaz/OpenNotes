FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY *.mjs ./
COPY public ./public
USER node
ENV PORT=3000 \
    NOTES_FONT_REGULAR=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
    NOTES_FONT_BOLD=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
    NOTES_FONT_ITALIC=/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf \
    NOTES_FONT_BOLD_ITALIC=/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf
EXPOSE 3000
CMD ["node", "index.mjs"]
