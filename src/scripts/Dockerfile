FROM python:3.12-slim

WORKDIR /app

# Install kubectl for scripts that shell out
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
  && curl -sSL "https://dl.k8s.io/release/$(curl -sSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py ./

# Scripts run as non-root
RUN useradd -r -u 1000 platform
USER platform

ENTRYPOINT ["python"]
