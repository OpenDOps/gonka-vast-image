# Use base image that contains all dependencies
# ARG must be declared before FROM to use in FROM statement
ARG GITHUB_REPOSITORY
ARG BASE_IMAGE_TAG=latest
FROM ghcr.io/${GITHUB_REPOSITORY}-base:${BASE_IMAGE_TAG}

# Copy start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV HF_HOME=/data/hf-cache
ENV MODEL_NAME=Qwen/Qwen3-32B-FP8

WORKDIR /app

# Use start script as entrypoint
ENTRYPOINT ["/start.sh"]

