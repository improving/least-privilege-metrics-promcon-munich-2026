FROM python:3.12-slim
ARG KYVERNO_VERSION=v1.19.1
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo x86_64) \
 && curl -sSL "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/kyverno-cli_${KYVERNO_VERSION}_linux_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin kyverno \
 && apt-get purge -y curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
USER 65534
ENV HOME=/tmp
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "warning"]
