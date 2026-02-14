// ======================================================
// 0. パラメータ定義
// ======================================================
// デプロイ時に外部から渡せる値
// デフォルト値を設定しているのでそのままでもデプロイ可能
@description('リソースを配置する場所')
param location string = resourceGroup().location

@description('ストレージアカウントの一意の名前')
param storageAccountName string = 'stlogsim2026'

@description('Azure Functionsの一意の名前')
param functionAppName string = 'fn-batch-sim-20260211'

@description('App Service Planの名前')
param appServicePlanName string = 'ASP-RGPortfolioAutomation'

@description('Application Insightsの名前')
param appInsightsName string = 'ai-batch-sim-20260211'

@description('Log Analytics Workspaceの名前')
param logAnalyticsName string = 'law-portfolio-automation'


// ======================================================
// 1. Log Analytics Workspace
// ======================================================
// Azure上でログを収集・分析するためのワークスペース
// Function Appやストレージの診断ログを集約できる
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }      // 従量課金プラン
    retentionInDays: 30             // データ保持日数（30日）
  }
}


// ======================================================
// 2. ストレージアカウント
// ======================================================
// Function App が内部で使用するストレージ
// BlobやQueue、Tableを保持できる
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }    // 標準冗長（ローカル）
  kind: 'StorageV2'                // 最新のストレージタイプ
  properties: {
    accessTier: 'Hot'                      // 頻繁にアクセスするデータ向け
    supportsHttpsTrafficOnly: true         // HTTPSのみ許可
    allowBlobPublicAccess: false           // 公開禁止
    minimumTlsVersion: 'TLS1_2'            // TLS1.2以上
    defaultToOAuthAuthentication: true     // 安全な認証方式
  }
}


// ======================================================
// 3. App Service Plan
// ======================================================
// Function Appを動かすための実行基盤
// LinuxのConsumptionプラン（Y1/Dynamic）で自動スケール
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux利用
  }
}


// ======================================================
// 4. Application Insights
// ======================================================
// Function Appの動作監視やログ収集に使用
// Log Analytics Workspace にも接続
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}


// ======================================================
// 5. Azure Functions 本体
// ======================================================
// 実際にFunction Appを作成する
// マネージドIDを付与してAzureリソースへのアクセス権限を付与
var storageKeys = storageAccount.listKeys()
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageKeys.keys[0].value};EndpointSuffix=core.windows.net'

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned' // 自動でマネージドIDを付与
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true  // HTTPSのみ許可
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|8.0' // .NET 8.0 Isolated Worker
      minTlsVersion: '1.2'                 // 最低TLSバージョン
      ftpsState: 'Disabled'                 // FTPを無効化
      appSettings: [
        { name: 'AzureWebJobsStorage', value: storageConnectionString } // ストレージ接続文字列
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString } // App Insights 接続
        { name: 'StorageConfig__blobServiceUri', value: storageAccount.properties.primaryEndpoints.blob } // Blob URL
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' } // Workerランタイム
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }          // Functionsバージョン
      ]
    }
  }
}


// ======================================================
// 6. 診断設定（Function App / Blob）
// ======================================================
// Function AppのログをLog Analyticsに送る
resource functionDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law-logs'
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      { category: 'FunctionAppLogs', enabled: true } // 標準ログ
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true } // メトリクスも収集
    ]
  }
}

// Blobストレージの診断設定
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource storageDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law-blob-logs'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      { category: 'StorageWrite', enabled: true }  // 書き込みログ
      { category: 'StorageDelete', enabled: true } // 削除ログ
    ]
    metrics: [
      { category: 'Transaction', enabled: true }   // ストレージの処理メトリクス
    ]
  }
}


// ======================================================
// 7. RBAC（マネージドIDにストレージ権限付与）
// ======================================================
// Function App がBlobを操作できるように権限を割り当て
var blobRoleId  = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Owner

resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'blob') // 一意の名前を生成
  scope: storageAccount
  properties: {
    roleDefinitionId: blobRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal' // マネージドID用
  }
}
