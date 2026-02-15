// ======================================================
// 0. パラメータ定義
// ======================================================

@description('リソースを配置する場所（リソースグループの場所を継承）')
param location string = resourceGroup().location

@description('ストレージアカウントの一意の名前')
param storageAccountName string = 'stlogsim2026'

@description('Azure Functionsの一意の名前')
param functionAppName string = 'fn-batch-sim-20260211'

@description('関数アプリを動かすサーバーレス実行基盤の名前')
param appServicePlanName string = 'ASP-RGPortfolioAutomation'

@description('アプリのパフォーマンスやエラーを監視するApplication Insightsの名前')
param appInsightsName string = 'ai-batch-sim-20260211'

@description('すべてのログを集約してKQLで分析するためのワークスペース名')
param logAnalyticsName string = 'law-portfolio-automation'


// ======================================================
// 1. Log Analytics Workspace
// ======================================================

// ログを集約する場所であり、関数アプリやストレージの稼働データをここに集め、KQLで分析可能にする。
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    // 1GBごとの従量課金であり、個人開発や少量ログ向け
    sku: { name: 'PerGB2018' }
    // コスト抑制のため、データ保持期間を最短の30日に設定
    retentionInDays: 30
  }
}


// ======================================================
// 2. ストレージアカウント
// ======================================================

// 生成されたログファイルの保存先
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  // 冗長性を抑えてコストを最小化
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    // 頻繁な読み書きに適したHot層
    accessTier: 'Hot'
    // 外部からの匿名アクセスを禁止するセキュリティ設定「https」
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    // 鍵ではなく「権限」によるアクセスを優先
    defaultToOAuthAuthentication: true
  }
}


// ======================================================
// 3. App Service Plan
// ======================================================

// 関数アプリを動かすサーバーレスな実行基盤
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    // 消費プラン（Consumption）：実行された分だけ課金され、月100万実行まで無料
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    // Linux OS を使用。
    reserved: true
  }
}


// ======================================================
// 4. Application Insights
// ======================================================

// アプリケーション診断であり、実行回数やエラーをリアルタイム監視
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    // 収集した生データを保存するために Log Analyticsワークスペースと紐付け
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}


// ======================================================
// 5. Azure Functions 本体
// ======================================================

// プログラムが実際に稼働するリソース
// 内部動作に必要なストレージキーを一時的に取得。
var storageKeys = storageAccount.listKeys()

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  // 「システム割り当てマネージドID」を有効化し、Function自身がAzure内で身分証明を所持
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      // .NET 8 Isolated 実行環境の指定
      linuxFxVersion: 'DOTNET-ISOLATED|8.0'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        // アプリケーションの動作に必要な内部ストレージ接続。
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageKeys.keys[0].value};EndpointSuffix=core.windows.net'
        }
        // Application Insights への接続文字列
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // C#コードから参照する Blob URLであり、接続文字列ではなくURLのみを持たせることでよりセキュアに
        { name: 'StorageConfig__blobServiceUri', value: storageAccount.properties.primaryEndpoints.blob }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
      ]
    }
  }
}


// ======================================================
// 6. 診断設定（監視の統合）
// ======================================================

// 関数アプリのシステムログをLog Analyticsに転送する設定
resource functionDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law-logs'
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      { category: 'FunctionAppLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ストレージへの「書き込み」「削除」イベントを監視
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
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}


// ======================================================
// 7. RBAC（権限の自動割り当て）
// ======================================================

// ストレージBlobデータ共同作成者の権限ID
var blobRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

// 関数アプリ（マネージドID）に対して、ストレージを操作する権限を付与し、プログラムから接続文字列を使わずにBlobを操作
resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // 名前は一意である必要があるため、IDを組み合わせて生成。
  name: guid(storageAccount.id, functionApp.id, 'blob')
  scope: storageAccount
  properties: {
    roleDefinitionId: blobRoleId
    // 上記で作成したIDを紐付け。
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
