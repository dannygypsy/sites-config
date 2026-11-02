# Caddy plus the two Cloudflare plugins this setup needs:
#   caddy-dns/cloudflare       certificates via Cloudflare DNS (works with the orange cloud on)
#   caddy-cloudflare-ip        Cloudflare's IP ranges, so Caddy can trust it and see real visitor IPs
FROM caddy:2-builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/WeidiDeng/caddy-cloudflare-ip

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
