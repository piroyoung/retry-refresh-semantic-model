# retry-refresh-semantic-model

> [!WARNING]
> 本リポジトリはデモ・サンプル実装です。動作・セキュリティ・運用品質について **いかなる保証も行いません**。本番環境での利用や顧客環境への適用にあたっては、内容を十分にレビューしたうえで **自己責任** にてご利用ください。

Microsoft Fabric ワークスペース内のセマンティックモデルの直近の更新ステータスを取得し、`Failed` のものを再実行する Shell Script と、Azure Container Apps Job で動かすための Dockerfile。

## ワンクリックデプロイ

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpiroyoung%2Fretry-refresh-semantic-model%2Fmain%2Fdeploy%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpiroyoung%2Fretry-refresh-semantic-model%2Fmain%2Fdeploy%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fpiroyoung%2Fretry-refresh-semantic-model%2Fmain%2Fdeploy%2Fazuredeploy.json)

ボタンクリック後、Azure ポータルのフォームで **Fabric ワークスペース名** と **Cron 式** を入力するだけで以下が一括デプロイされます。

- User Assigned Managed Identity
- Log Analytics Workspace
- Container Apps Environment
- Container Apps Job (スケジュール実行 / GHCR の公開イメージを利用)

### デプロイ後に必要な作業 (1 ステップ)

Fabric の RBAC は ARM では設定できないため、デプロイ後に **Fabric ポータル** で以下を行ってください。

1. 対象 Fabric ワークスペース → **アクセス管理** を開く
2. デプロイで作成された **Managed Identity (`<prefix>-mi`)** を **Contributor** として追加

これだけで Container Apps Job がスケジュールに従って実行されます。手動実行は次のコマンドでも可能です:

```bash
az containerapp job start -n <prefix>-job -g <resource-group>
```

## 構成

- [retry-refresh.sh](retry-refresh.sh) — メインスクリプト（Managed Identity でサインイン → モデル一覧 → 失敗検出 → 再実行）
- [Dockerfile](Dockerfile) — `mcr.microsoft.com/azure-cli` をベースにした実行イメージ

## 必要な権限

Container Apps Job に割り当てる Managed Identity に対して、対象 Fabric ワークスペースの **Contributor 以上** のロールを付与してください（Power BI dataset refresh API を呼ぶため）。

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
  --env-vars WORKSPACE_NAME=<FABRIC_WORKSPACE_NAME> AZURE_CLIENT_ID=<UAMI_CLIENT_ID>
```

## 動作概要

1. Managed Identity で `az login --identity`
2. Fabric API (`https://api.fabric.microsoft.com`) と Power BI API (`https://analysis.windows.net/powerbi/api`) のトークンを取得
3. ワークスペース名から `workspaceId` を解決
4. ワークスペース内の `semanticModels` を列挙
5. 各モデルの最新 refresh 履歴 (`/refreshes?$top=1`) を取得
6. `status == Failed` の場合、`POST /refreshes` で再実行をキューに登録
7. 結果サマリを stdout に出力。再実行トリガに失敗があれば exit 1

