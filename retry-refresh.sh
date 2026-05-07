#!/usr/bin/env bash
#
# retry-refresh.sh
#
# Microsoft Fabric ワークスペース内のすべてのセマンティックモデルの
# 直近の更新 (refresh) ログを取得し、Failed だったものを再実行する。
#
# 実行環境: Azure Container Apps Job (User Assigned / System Assigned Managed Identity)
#   - Managed Identity に対して、対象 Fabric ワークスペースの「メンバー」以上の
#     ロール (Contributor 推奨) を付与しておくこと。
#
# 必要な環境変数:
#   WORKSPACE_NAME        : 対象 Fabric ワークスペース名 (必須)
#   AZURE_CLIENT_ID       : User Assigned Managed Identity を使う場合に指定 (任意)
#
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
POWERBI_API="https://api.powerbi.com/v1.0/myorg"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

: "${WORKSPACE_NAME:?環境変数 WORKSPACE_NAME を設定してください (例: demo-02)}"

command -v az    >/dev/null || die "az CLI が必要です"
command -v jq    >/dev/null || die "jq が必要です"
command -v curl  >/dev/null || die "curl が必要です"

# --- 1. Managed Identity でログイン -----------------------------------------
log "Managed Identity でサインイン中..."
if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
  az login --identity --client-id "${AZURE_CLIENT_ID}" --allow-no-subscriptions >/dev/null
else
  az login --identity --allow-no-subscriptions >/dev/null
fi

get_token() {
  local resource="$1"
  az account get-access-token --resource "${resource}" --query accessToken -o tsv
}

FABRIC_TOKEN="$(get_token https://api.fabric.microsoft.com)"
PBI_TOKEN="$(get_token https://analysis.windows.net/powerbi/api)"

api_get() {
  # $1: token, $2: url
  curl -sS --fail-with-body \
    -H "Authorization: Bearer $1" \
    -H "Accept: application/json" \
    "$2"
}

api_post() {
  # $1: token, $2: url, $3: body (任意)
  local body="${3:-}"
  if [[ -n "${body}" ]]; then
    curl -sS --fail-with-body \
      -H "Authorization: Bearer $1" \
      -H "Content-Type: application/json" \
      -X POST -d "${body}" \
      "$2"
  else
    curl -sS --fail-with-body \
      -H "Authorization: Bearer $1" \
      -X POST \
      "$2"
  fi
}

# --- 2. ワークスペース ID を解決 --------------------------------------------
log "ワークスペース '${WORKSPACE_NAME}' を検索中..."
WORKSPACE_ID="$(api_get "${FABRIC_TOKEN}" "${FABRIC_API}/workspaces" \
  | jq -r --arg name "${WORKSPACE_NAME}" \
      '.value[] | select(.displayName == $name) | .id' | head -n1)"

[[ -n "${WORKSPACE_ID}" && "${WORKSPACE_ID}" != "null" ]] \
  || die "ワークスペース '${WORKSPACE_NAME}' が見つかりません"
log "WorkspaceId = ${WORKSPACE_ID}"

# --- 3. セマンティックモデル一覧取得 ----------------------------------------
log "セマンティックモデルを列挙中..."
MODELS_JSON="$(api_get "${FABRIC_TOKEN}" \
  "${FABRIC_API}/workspaces/${WORKSPACE_ID}/semanticModels")"

MODEL_COUNT="$(echo "${MODELS_JSON}" | jq '.value | length')"
log "セマンティックモデル数: ${MODEL_COUNT}"
[[ "${MODEL_COUNT}" -gt 0 ]] || { log "対象がありません。終了します。"; exit 0; }

# --- 4. 各モデルの最新リフレッシュをチェックし、失敗していれば再実行 -------
FAILED_COUNT=0
RETRIED_COUNT=0
RETRY_FAILED_COUNT=0

while IFS=$'\t' read -r MODEL_ID MODEL_NAME; do
  log "----- ${MODEL_NAME} (${MODEL_ID}) -----"

  # 直近 1 件の refresh 履歴
  REFRESH_URL="${POWERBI_API}/groups/${WORKSPACE_ID}/datasets/${MODEL_ID}/refreshes?\$top=1"
  if ! HISTORY_JSON="$(api_get "${PBI_TOKEN}" "${REFRESH_URL}" 2>&1)"; then
    log "  WARN: refresh 履歴の取得に失敗 (権限不足の可能性): ${HISTORY_JSON}"
    continue
  fi

  LATEST="$(echo "${HISTORY_JSON}" | jq -c '.value[0] // empty')"
  if [[ -z "${LATEST}" ]]; then
    log "  refresh 履歴なし。スキップ。"
    continue
  fi

  STATUS="$(echo "${LATEST}" | jq -r '.status')"
  END_TIME="$(echo "${LATEST}" | jq -r '.endTime // .startTime // "-"')"
  log "  最新ステータス: ${STATUS} (${END_TIME})"

  if [[ "${STATUS}" == "Failed" ]]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    log "  Failed を検出。再実行をトリガします..."
    if api_post "${PBI_TOKEN}" \
        "${POWERBI_API}/groups/${WORKSPACE_ID}/datasets/${MODEL_ID}/refreshes" \
        '{"notifyOption":"NoNotification"}' >/dev/null; then
      RETRIED_COUNT=$((RETRIED_COUNT + 1))
      log "  再実行をキューに登録しました。"
    else
      RETRY_FAILED_COUNT=$((RETRY_FAILED_COUNT + 1))
      log "  ERROR: 再実行のトリガに失敗しました。"
    fi
  fi
done < <(echo "${MODELS_JSON}" | jq -r '.value[] | [.id, .displayName] | @tsv')

# --- 5. サマリ ---------------------------------------------------------------
log "==================== Summary ===================="
log "  対象モデル数        : ${MODEL_COUNT}"
log "  Failed 検出数       : ${FAILED_COUNT}"
log "  再実行成功数        : ${RETRIED_COUNT}"
log "  再実行トリガ失敗数  : ${RETRY_FAILED_COUNT}"
log "================================================="

# 再実行トリガに失敗したものがあれば非ゼロ終了 (Container Apps Job がリトライ可能)
[[ "${RETRY_FAILED_COUNT}" -eq 0 ]] || exit 1
