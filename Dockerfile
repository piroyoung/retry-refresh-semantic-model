# syntax=docker/dockerfile:1.7
#
# Container Apps Job 用イメージ
#  - az CLI + jq + curl + bash を含む軽量イメージ
#  - 起動時に retry-refresh.sh を実行
#
FROM mcr.microsoft.com/azure-cli:latest

# Azure Linux ベースイメージのため tdnf を使用
# - jq: JSON 処理
# - shadow-utils: useradd を提供 (非 root 実行用)
RUN tdnf install -y jq ca-certificates shadow-utils && tdnf clean all

WORKDIR /app
COPY retry-refresh.sh /app/retry-refresh.sh
RUN chmod +x /app/retry-refresh.sh

# 非 root ユーザーで実行 (HOME は az CLI のキャッシュに必要)
RUN useradd -m -u 10001 -d /home/runner runner
USER 10001
ENV HOME=/home/runner

ENTRYPOINT ["/app/retry-refresh.sh"]
