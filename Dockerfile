FROM debian:trixie-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends libchatbot-eliza-perl libmojolicious-perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY lib/ lib/
COPY bin/ bin/
ENV MOJO_MODE=production
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["perl", "-MMojo::UserAgent", "-e", "exit(Mojo::UserAgent->new->request_timeout(2)->get('http://127.0.0.1:8080/healthz')->result->is_success ? 0 : 1)"]
ENTRYPOINT ["perl", "bin/server"]
CMD ["daemon", "-l", "http://0.0.0.0:8080"]

FROM base AS perl-tests
COPY t/ t/
ENTRYPOINT ["prove", "-Ilib", "-v", "t"]

FROM base AS runtime
