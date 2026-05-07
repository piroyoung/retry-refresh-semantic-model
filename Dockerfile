# syntax=docker/dockerfile:1.7
#
# Container Apps Job 用イメージ
#  - az CLI + jq + curl + bash を含む軽量イメージ
#  - 起動時に retry-refresh.sh を実行
#
FROM mcr.microsoft.com/azure-cli:latest

# jq は azure-cli イメージに含まれない場合があるためインストール
RUN tdnf install -y jq ca-certificates && tdnf clean all \
 || (apk add --no-cache jq ca-certificates) \
 || (apt-get update && apt-get install -y --no-install-recommends jq ca-certificates && rm -rf /var/lib/apt/lists/*)

WORKDIR /app
COPY retry-refresh.sh /app/retry-refresh.sh
RUN chmod +x /app/retry-refresh.sh

# 非 root ユーザーで実行
RUN useradd -m -u 10001 runner || adduser -D -u 10001 runner
USER 10001

ENTRYPOINT ["/app/retry-refresh.sh"]
