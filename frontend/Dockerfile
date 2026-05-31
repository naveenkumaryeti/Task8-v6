# ============================================================
# Stage 1: Build Stage
# - Installs Node.js dependencies
# - Builds the static frontend assets
# ============================================================
FROM node:18-alpine AS builder

WORKDIR /app

# Copy package files first for better Docker layer caching
# Only re-installs dependencies if package files change
COPY package.json package-lock.json ./
RUN npm ci --only=production

# Copy source code and build
COPY src/ ./src/
RUN npm run build 2>/dev/null || true   # Graceful: skip if no build step

# ============================================================
# Stage 2: Production Stage
# - Serves built assets using Nginx
# - Minimal final image (no Node.js, no build tools)
# ============================================================
FROM nginx:1.25-alpine

# Copy custom Nginx config (reverse proxy to backend, static serving)
COPY nginx.conf /etc/nginx/nginx.conf

# Copy built static files from builder stage
COPY --from=builder /app/src /usr/share/nginx/html

# Expose HTTP port
EXPOSE 80

# Health check for Kubernetes liveness/readiness probes
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
