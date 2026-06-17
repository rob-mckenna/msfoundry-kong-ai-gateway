FROM kong:3.7

# Copy declarative config
COPY kong.yaml /etc/kong/kong.yaml

# Kong configuration
ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_ERROR_LOG=/dev/stderr \
    KONG_STATUS_LISTEN=0.0.0.0:8100 \
    KONG_ADMIN_LISTEN=off \
    KONG_UNTRUSTED_LUA=on

EXPOSE 8000 8443 8100

# Verify config file exists
RUN ls -la /etc/kong/kong.yaml

# Capture managed identity env vars before nginx strips them, then start Kong
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["echo \"IDENTITY_ENDPOINT=${IDENTITY_ENDPOINT}\" > /tmp/mi_env && echo \"IDENTITY_HEADER=${IDENTITY_HEADER}\" >> /tmp/mi_env && exec /docker-entrypoint.sh kong docker-start"]
