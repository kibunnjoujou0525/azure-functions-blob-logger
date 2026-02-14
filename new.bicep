// ======================================================
// deploy.bicep
// Azure Function App 一式をデプロイするテンプレート
// ======================================================


// ======================================================
// 0. パラメータ（外から渡せる値）
// ======================================================

param location string = resourceGroup().location
param storageAccountName string
param appServicePlanName string
param functionAppName string
param appInsightsName string


// ======================================================
// 1. Storage Account
// Function が内部で使用するストレージ
// ======================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}


// ======================================================
// 2. Application Insights
// ログ・監視用
// ======================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}


// ======================================================
// 3. App Service Plan
// Function の実行基盤（Consumption プラン）
// ======================================================

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true  // Linux利用
  }
}


// ======================================================
// 4. Storage 接続文字列の生成
// ======================================================

var storageKey = listKeys(storageAccount.id, '2023-01-01').keys[0].value
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageKey};EndpointSuffix=core.windows.net'


// ======================================================
// 5. Function App の設定値まとめ
// ======================================================

var functionAppSettings = [
  {
    name: 'AzureWebJobsStorage'
    value: storageConnectionString
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: reference(appInsights.id, '2020-02-02').ConnectionString
  }
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'dotnet-isolated'
  }
]


// ======================================================
// 6. Function App 本体
// ======================================================

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      appSettings: functionAppSettings
      linuxFxVersion: 'DOTNET-ISOLATED|8.0'
    }
  }
}
