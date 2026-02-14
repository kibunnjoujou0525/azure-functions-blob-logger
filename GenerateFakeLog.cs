using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Portfolio.Function
{
    public class GenerateFakeLog
    {
        private readonly ILogger _logger;

        // コンストラクタで ILogger を受け取り、関数内で利用可能に
        public GenerateFakeLog(ILoggerFactory loggerFactory)
        {
            _logger = loggerFactory.CreateLogger<GenerateFakeLog>();
        }

        // Timer Trigger: 1分ごとに実行
        [Function("GenerateFakeLog")]
        public async Task Run([TimerTrigger("0 */1 * * * *")] TimerInfo myTimer, FunctionContext context)
        {
            // 関数実行時のログ取得
            var _logger = context.GetLogger("GenerateFakeLog");

            try
            {
                // ==========================================
                // 1. 環境変数からストレージサービスのURIを取得
                // ==========================================
                // - 接続文字列のべた書きを廃止
                // - ローカル: local.settings.json
                // - クラウド: Bicepで定義した appSettings
                string? storageAccountUri = Environment.GetEnvironmentVariable("StorageConfig__blobServiceUri");

                if (string.IsNullOrEmpty(storageAccountUri))
                {
                    // 環境変数が設定されていない場合は明示的に例外を投げる
                    throw new Exception("環境変数 'StorageConfig__blobServiceUri' が設定されていません。");
                }

                // ==========================================
                // 2. BlobServiceClient の初期化
                // ==========================================
                // - DefaultAzureCredential を利用
                // - マネージドID / Visual Studio / CLI など複数の認証を自動検出
                var blobServiceClient = new BlobServiceClient(
                    new Uri(storageAccountUri),
                    new DefaultAzureCredential()
                );

                // ==========================================
                // 3. 環境ごとのログ格納フォルダ設定
                // ==========================================
                // - 開発環境: dev
                // - 本番環境: prod (WEBSITE_SITE_NAME が存在する場合)
                string? siteName = Environment.GetEnvironmentVariable("WEBSITE_SITE_NAME");
                string folderPath = string.IsNullOrEmpty(siteName) ? "dev" : "prod";

                // ==========================================
                // 4. コンテナ取得・作成
                // ==========================================
                // - 保存先コンテナ名: "logs"
                var containerClient = blobServiceClient.GetBlobContainerClient("logs");
                await containerClient.CreateIfNotExistsAsync();

                // ==========================================
                // 5. ファイル名と内容を作成
                // ==========================================
                // - 日時を付与してファイル名の重複を回避
                string fileName = $"{folderPath}/log-{DateTime.UtcNow:yyyyMMddHHmmss}.txt";

                // - ログ内容
                string content = $"[{DateTime.UtcNow:O}] INFO: Passwordless Execution\n" +
                                 $"Env: {folderPath}\n" +
                                 $"Status: Success";

                // ==========================================
                // 6. Blob にアップロード
                // ==========================================
                using var ms = new MemoryStream(Encoding.UTF8.GetBytes(content));
                await containerClient.UploadBlobAsync(fileName, ms);

                // ==========================================
                // 7. Azure Functions 実行ログに記録
                // ==========================================
                _logger.LogInformation($"Successfully uploaded: {fileName}");
            }
            catch (Exception ex)
            {
                // ==========================================
                // エラー時のログ出力
                // ==========================================
                _logger.LogError($"Fatal Error: {ex.Message}");
            }
        }
    }
}
