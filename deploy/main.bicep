@description('デプロイ名のプレフィックス（リソース名に使用）')
param namePrefix string = 'fabric-refresh-retry'

@description('Azure リージョン')
param location string = resourceGroup().location

@description('対象 Microsoft Fabric ワークスペース名')
param workspaceName string

@description('cron 実行スケジュール (UTC)。デフォルトは 1 時間ごと')
param cronExpression string = '0 * * * *'

@description('使用するコンテナイメージ')
param containerImage string = 'ghcr.io/piroyoung/retry-refresh-semantic-model:latest'

@description('Job タイムアウト秒')
param replicaTimeout int = 1800

var uniqueSuffix = toLower(uniqueString(resourceGroup().id, namePrefix))
var uamiName = '${namePrefix}-mi'
var lawName = '${namePrefix}-law-${uniqueSuffix}'
var envName = '${namePrefix}-env'
var jobName = '${namePrefix}-job'

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: jobName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    environmentId: env.id
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: replicaTimeout
      replicaRetryLimit: 1
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'retry-refresh'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'WORKSPACE_NAME'
              value: workspaceName
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: uami.properties.clientId
            }
          ]
        }
      ]
    }
  }
}

output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
output managedIdentityName string = uami.name
output jobName string = job.name
output environmentName string = env.name
