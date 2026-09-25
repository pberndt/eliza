FROM debian:trixie-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends libchatbot-eliza-perl libmojolicious-perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY lib/ lib/
COPY bin/ bin/
# Application code is read-only and accessible to any OpenShift-assigned UID,
# regardless of the permissions in the build checkout. Only /tmp is writable.
RUN chmod -R a=rX /app
ENV MOJO_MODE=production \
    HOME=/tmp \
    TMPDIR=/tmp
USER 10001:0
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["perl", "-MMojo::UserAgent", "-e", "exit(Mojo::UserAgent->new->request_timeout(2)->get('http://127.0.0.1:8080/healthz')->result->is_success ? 0 : 1)"]
ENTRYPOINT ["perl", "bin/server"]
CMD ["daemon", "-l", "http://0.0.0.0:8080"]

FROM base AS perl-tests
COPY t/ t/
ENTRYPOINT ["prove", "-Ilib", "-v", "t"]

FROM base AS runtime
