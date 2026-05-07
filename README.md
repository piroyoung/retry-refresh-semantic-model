# retry-refresh-semantic-model

Microsoft Fabric ワークスペース `demo-02` 内のセマンティックモデルの直近の更新ステータスを取得し、`Failed` のものを再実行する Shell Script と、Azure Container Apps Job で動かすための Dockerfile。

## 構成

- [retry-refresh.sh](retry-refresh.sh) — メインスクリプト（Managed Identity でサインイン → モデル一覧 → 失敗検出 → 再実行）
- [Dockerfile](Dockerfile) — `mcr.microsoft.com/azure-cli` をベースにした実行イメージ

## 必要な権限

Container Apps Job に割り当てる Managed Identity に対して、対象 Fabric ワークスペース (`demo-02`) の **Contributor 以上** のロールを付与してください（Power BI dataset refresh API を呼ぶため）。

## 環境変数

| 変数名 | 説明 | 必須 |
| --- | --- | --- |
| `WORKSPACE_NAME` | 対象 Fabric ワークスペース名 | ✅ |
| `AZURE_CLIENT_ID` | User Assigned Managed Identity の Client ID | — |

## ビルド & デプロイ例

```bash
# 1. ACR へビルド & プッシュ
az acr build -r <ACR_NAME> -t fabric-refresh-retry:latest .

# 2. Container Apps Job を作成（例: 1 時間おきにスケジュール実行）
az containerapp job create \
  --name fabric-refresh-retry \
  --resource-group <RG> \
  --environment <ACA_ENV> \
  --trigger-type Schedule \
  --cron-expression "0 * * * *" \
  --replica-timeout 1800 \
  --image <ACR_NAME>.azurecr.io/fabric-refresh-retry:latest \
  --mi-user-assigned <UAMI_RESOURCE_ID> \
  --registry-identity <UAMI_RESOURCE_ID> \
  --registry-server <ACR_NAME>.azurecr.io \
  --env-vars WORKSPACE_NAME=demo-02 AZURE_CLIENT_ID=<UAMI_CLIENT_ID>
```

## 動作概要

1. Managed Identity で `az login --identity`
2. Fabric API (`https://api.fabric.microsoft.com`) と Power BI API (`https://analysis.windows.net/powerbi/api`) のトークンを取得
3. ワークスペース名から `workspaceId` を解決
4. ワークスペース内の `semanticModels` を列挙
5. 各モデルの最新 refresh 履歴 (`/refreshes?$top=1`) を取得
6. `status == Failed` の場合、`POST /refreshes` で再実行をキューに登録
7. 結果サマリを stdout に出力。再実行トリガに失敗があれば exit 1

