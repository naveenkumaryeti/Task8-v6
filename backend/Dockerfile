# ============================================================
# Stage 1: Dependency Installation
# - Uses full Node image for npm install
# - Separate layer so prod deps are cached independently
# ============================================================
FROM node:18-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./

# Install ONLY production dependencies (no devDependencies in final image)
# --omit=dev reduces image size by ~60% on most projects
RUN npm ci --omit=dev

# ============================================================
# Stage 2: Production Runtime
# - Minimal Alpine image (~50MB vs ~900MB for full Node)
# - Runs as non-root user (security best practice)
# ============================================================
FROM node:18-alpine AS production

# Install dumb-init: proper PID 1 for signal handling in containers
# Without it, SIGTERM from kubectl may not reach the Node process
RUN apk add --no-cache dumb-init

WORKDIR /app

# Create non-root user/group for running the app
RUN addgroup -g 1001 -S nodejs && \
    adduser  -S nodeuser -u 1001 -G nodejs

# Copy production node_modules from deps stage
COPY --from=deps --chown=nodeuser:nodejs /app/node_modules ./node_modules

# Copy application source
COPY --chown=nodeuser:nodejs src/ ./src/
COPY --chown=nodeuser:nodejs package.json ./

# Switch to non-root user
USER nodeuser

# Expose application port
EXPOSE 3000

# Health check for Kubernetes probes
# NOTE: Probes must NOT check the database here.
#       Liveness probe checks only if the process is alive.
#       Readiness probe (in k8s yaml) checks /api/health which validates DB.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/api/ping || exit 1

# Use dumb-init as PID 1 so Node receives OS signals correctly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
