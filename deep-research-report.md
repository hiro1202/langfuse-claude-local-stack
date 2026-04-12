# エグゼクティブサマリ

- **前提条件**：Linux/macOS/Windows上でDocker Engine（Docker Compose含む）が利用可能であること。推奨ハードウェアは「4コア/16GBメモリ/100GB以上のディスク容量」【46†L125-L128】。ファイアウォールではLangfuse UI(3000番)とMinIO(9090番)のみ開放し、他はローカルホスト限定アクセスとする【5†L601-L610】【46†L179-L182】。OSやDockerの最小バージョンは公式未指定のため、最新安定版を推奨。ネットワークはDockerデフォルト（ブリッジ）で構いません。

- **構成とコンテナ**：Langfuse本体は`langfuse/langfuse:3`（webサーバ）と`langfuse/langfuse-worker:3`（ワーカー）コンテナで構成されます【35†L614-L622】【35†L756-L764】。データストアとしてPostgreSQL（デフォルトタグ17）、ClickHouse、Redis 7、およびオブジェクトストレージ用にMinIO（Chainguard版）を使用します【35†L614-L622】【6†L830-L839】。各サービスの依存関係とポート割当を下図のようにまとめました。  

```mermaid
graph LR
    subgraph Langfuseサービス群
      LFWeb[langfuse-web:3000] 
      LFWorker[langfuse-worker]
      Postgres[PostgreSQL:5432]
      Clickhouse[ClickHouse:8123/9000]
      Redis[Redis:6379]
      MinIO[MinIO S3:9000 (端末:9090)]
    end
    LFWeb -- DB接続 --> Postgres
    LFWeb -- 分析DB --> Clickhouse
    LFWeb -- キャッシュ --> Redis
    LFWeb -- メディア・イベント --> MinIO
    LFWorker -- DB接続 --> Postgres
    LFWorker -- 分析DB --> Clickhouse
    LFWorker -- キャッシュ --> Redis
    LFWorker -- メディア・イベント --> MinIO
    クライアント-->LFWeb
```

- **環境変数**：Langfuseでは多くの設定を環境変数で行います。主要なものは下表の通りです。シークレット（パスワードやキー）は`.env`ファイルやDockerシークレットで安全に管理してください。特に、Postgres/Redis/MinIOのパスワードや、`SALT`・`ENCRYPTION_KEY`・`NEXTAUTH_SECRET`などは長くランダムな文字列を使用し、コードリポジトリに含めないようにします。

| 変数名 | 説明 | デフォルト／例 |
|:-------|:------|:---------------|
| `NEXTAUTH_URL` | NextAuthのコールバックURL。Langfuse UI（例: `http://localhost:3000`）に設定【35†L644-L652】。 | `http://localhost:3000` |
| `DATABASE_URL` | PostgreSQL接続文字列【35†L646-L652】。例: `postgresql://postgres:password@postgres:5432/postgres` | - |
| `SALT` | 認証用Cookie暗号化シード【35†L650-L654】。ランダム文字列推奨 | - |
| `ENCRYPTION_KEY` | 敏感データ暗号化用32バイトキー【35†L650-L654】。`openssl rand -hex 32`で生成 | - |
| `CLICKHOUSE_URL`/`CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` | ClickHouse接続情報【35†L664-L668】。デフォルト: `clickhouse:8123`, ユーザー:`clickhouse` | - |
| `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` | MinIO(S3互換)のルート認証情報【6†L834-L842】【6†L845-L853】。必要に応じて変更 | 例: `minio` / `miniosecret` |
| `REDIS_HOST`/`REDIS_PORT`/`REDIS_AUTH` | Redis接続情報【35†L738-L742】。パスワード必須 | 例: `redis`, `6379`, `myredissecret` |
| `LANGFUSE_S3_EVENT_UPLOAD_*` / `LANGFUSE_S3_MEDIA_UPLOAD_*` | イベントやメディアファイルをS3/MinIOへ保存する設定【35†L674-L683】【35†L696-L704】。ローカル環境ではデフォルトのMinIO（`minio:miniosecret`）を使用。 | - |
| `NEXTAUTH_SECRET` | 認証用Secret【6†L772-L780】。ランダム文字列推奨 | - |
| `LANGFUSE_INIT_*` | 初期組織・プロジェクト・ユーザー作成用（ヘッドレスモード）【37†L93-L101】。起動時に自動で作成可能 | `LANGFUSE_INIT_ORG_ID`, `LANGFUSE_INIT_USER_EMAIL` など |

- **初期セットアップ**：Langfuseは起動時にDBマイグレーションを自動実行します。通常はUIから管理者ユーザー・組織・プロジェクトを作成しますが、`.env`で`LANGFUSE_INIT_*`変数を指定すればヘッドレスで自動作成できます【37†L71-L79】【37†L95-L104】。具体的には`LANGFUSE_INIT_ORG_ID`, `LANGFUSE_INIT_PROJECT_ID`, `LANGFUSE_INIT_PROJECT_PUBLIC_KEY`/`SECRET_KEY`, `LANGFUSE_INIT_USER_EMAIL/NAME/PASSWORD`を設定します【37†L95-L104】。これにより、起動時に指定組織・プロジェクト・管理ユーザーが作られ、そのプロジェクト用のAPIキーが生成されます。

- **Claude Code設定**：ローカルでClaude Codeを動かす環境は未指定のため「未指定」と明記します。Langfuse側では、Claude Codeのフックスクリプトからトレースを受け取るために、`~/.claude/settings.local.json`に以下の環境変数を設定します【40†L741-L748】【40†L753-L760】。例: 

```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true",
    "LANGFUSE_PUBLIC_KEY": "pk-lf-...",    // Langfuseプロジェクトの公開APIキー
    "LANGFUSE_SECRET_KEY": "sk-lf-...",    // Langfuseプロジェクトの秘密APIキー
    "LANGFUSE_BASE_URL": "http://localhost:3000"  // Self-hosted LangfuseのURL
  }
}
```

これにより、Claude Codeのフック（`langfuse_hook.py`）が有効化され、各ユーザー入力・AI応答・ツール呼び出しをLangfuseに送信します【40†L739-L748】【40†L755-L760】。Langfuseの受信エンドポイントはOTLP/HTTPや公開Ingestion API(`/api/public/ingestion`)です。Langfuse側では基本認証（プロジェクトの公開キー:秘密キー）またはSDK経由で送信されます【19†L120-L128】【40†L739-L748】。送信例（HTTPリクエスト）: 

```
curl -X POST "http://localhost:3000/api/public/ingestion" \
  -u "pk-lf-...:sk-lf-..." \
  -H "Content-Type: application/json" \
  -d '{"projectId":"<プロジェクトID>", "type":"trace", "data":{...トレースデータ...}}'
```

- **Langfuse SDK/クライアント設定例**：自前アプリからLangfuseへ送信する場合、言語別SDKを利用できます。Pythonでは環境変数または引数で`base_url`とAPIキーを設定します。例: 

```python
from langfuse import get_client
client = get_client(
    base_url="http://localhost:3000",
    public_key="pk-lf-YourPublicKey",
    secret_key="sk-lf-YourSecretKey"
)
```

Node.js/TypeScriptでは`@langfuse/client`を使います: 

```js
import { LangfuseClient } from "@langfuse/client";
const langfuse = new LangfuseClient({
  baseUrl: "http://localhost:3000",
  publicKey: "pk-lf-YourPublicKey",
  secretKey: "sk-lf-YourSecretKey"
});
```

これらを初期化後、SDK経由で自動トレースやデータ送信が可能です。

- **トレース送信例**：たとえば、Claude Codeのフックや自作コードで明示的にHTTP送信する際は、Observation JSONを構成します。以下にプロンプト送信（生成観察）の例スキーマを示します。実際には「observation」という概念で管理されますが、単純化してJSON例を示します。

```json
// 生成観察の例 (サーバーへPOSTするペイロードの例)
{
  "type": "trace",
  "projectId": "<プロジェクトID>",
  "data": {
    "observations": [
      {
        "type": "generation",
        "name": "claude-code-response",
        "input": { "messages": [{"role": "user","content": "質問内容"}] },
        "output": { "content": "Claudeの回答" },
        "metadata": { "session_id": "session123" },
        "model": "claude-3p0",
        "usage_details": { "input": 512, "output": 128 },
        "cost_details": { "input": 0.5, "output": 0.2 }
      }
    ]
  }
}
```

- **プロンプト管理例**：Langfuseのプロンプト管理ではSDK/API経由でプロンプトを作成・更新します。例として、Python SDKでテキストプロンプトを作成するコードは以下のようになります【48†L163-L171】。  

```python
langfuse.create_prompt(
    name="movie-critic",
    type="text",
    prompt="As a {{criticlevel}} movie critic, do you like {{movie}}?",
    labels=["production"]
)
```

JS/TS SDKでは同様に`langfuse.prompt.create({...})`で作成できます【48†L202-L210】。内部的にLangfuseサーバー上でプロンプトオブジェクトが管理され、バージョン管理・A/Bテストが可能です。

- **Evals（評価）の例**：カスタム評価結果は「スコア」（Score）としてLangfuseに送信します。Python SDK例【32†L152-L161】では、トレースIDとオブザベーションIDを指定して数値スコアを設定しています。JSONに直すと例として以下のような形になります。

```json
{
  "name": "correctness",
  "value": 0.9,
  "data_type": "NUMERIC",
  "trace_id": "<trace-id>",
  "observation_id": "<observation-id>",
  "comment": "回答は正確でした"
}
```

これをSDKの`create_score`やAPIに投げることで、指定トレース/観察に紐付いた評価が記録されます【32†L155-L163】。

- **コスト追跡の例**：Langfuseは生成観察に含まれる`usage_details`や`cost_details`を基にコストを計算します。Anthropic（Claude）から返る`response.usage`を使用し、SDKで`update_current_generation(usage_details=..., cost_details=...)`とする例が公式に示されています【30†L169-L178】。データとしては前述JSONの`usage_details`フィールドにトークン数等を含めます。コスト計算は内蔵のモデル定義（OpenAI/Anthropic等の料金表）を使って自動推定も可能です【30†L119-L127】。なお、生のコストは`cost_details`で明示的に上書きできます。  

```python
# Python SDK例: 使用量とコストを送信する
langfuse.update_current_generation(
    usage_details={"input": 1000, "output": 200},
    cost_details={"input": 0.5, "output": 0.1}
)
```

Langfuseはデフォルトで指定モデル（例: Claude 3）に基づく料金定義を持っており、使用量からUSDコストを算出します【30†L119-L127】。また、明示的な`usage_details`/`cost_details`があれば優先して使用されます【30†L129-L133】。

- **起動・動作確認**：ダウンロードした`docker-compose.yml`と`.env`（下記参照）を配置し、`docker compose up`を実行すると各コンテナが起動します。起動ログで`langfuse-web-1`が `"Ready"` とログ出力するまで待ちます【46†L187-L189】。その後、ブラウザで `http://localhost:3000` を開くとLangfuse UIにアクセスできます【1†L115-L117】。CLIからは`docker compose logs`で各コンテナのログを確認できます。サンプルとして、Langfuse SDKを用いたトレース送信や、Claude Codeを走らせて実際にダッシュボードの「Traces」「Prompt」「Scores」でデータを確認します。

- **トラブルシューティング**：よくある問題と対処法は以下の通りです。  
  - *PostgreSQLが落ちる*：デフォルト設定ではメモリ不足の恐れがあります【13†L441-L449】。`docker-compose.yml`のPostgres設定に`mem_limit: 512m`や`shared_buffers=256MB`等を追加してみてください（公式以外の事例ですが有効です）。  
  - *Claudeでトークン数が取れない*：Anthropicライブラリでは自動計測が抜ける場合があります。この場合、`response.usage`を明示的に`update_current_generation`で送る対応例が報告されています【13†L462-L470】。  
  - *トレースが見えない*：Langfuse Webコンテナのログを確認し、`/api/public/ingestion`に200系ステータスが返っているかをチェックします【24†L58-L67】。またRedis/MinIO/ClickHouseとの接続設定ミスがないか、`docker compose ps`で各コンテナのヘルスチェック状態を確認してください。  
  - *全コンテナが起動しない*：依存するRedis/MinIOが正常起動しないとLangfuseは待機します。必要に応じて`docker compose down -v`でボリュームを消去してクリーン起動を試してください。  

- **セキュリティ・運用上の注意**：Langfuse UI(3000)とMinIOコンソール(9090)以外は外部からアクセス禁止とし、ファイアウォールで通信制限してください【5†L601-L610】【46†L179-L182】。APIキーやDBパスワードはローカルファイル (`.env` など)に保存する場合はファイル権限を制限し、公開しないでください。CORSやHTTPSは必要に応じてリバースプロキシ（例：nginx）の設定で対応します。ローカル運用でも`NEXTAUTH_URL`等が外部から推測されると攻撃対象になるため注意してください。最小権限の原則からLangfuseコンテナには不要な機能をオフにし、Docker自体も定期的にアップデートしてセキュリティパッチを適用してください。

#### 参考資料 

- Langfuse公式セルフホスティングガイド【46†L125-L128】【46†L179-L182】、GitHubリポジトリ【35†L614-L622】【35†L756-L764】  
- Langfuse Claude Code統合ドキュメント【40†L741-L748】【40†L753-L760】  
- Langfuse公式各種SDK/APIリファレンス【19†L120-L128】【30†L119-L127】  

  

```yaml
# docker-compose.yml テンプレート例
version: '3.8'
services:
  langfuse-worker:
    image: docker.io/langfuse/langfuse-worker:3
    restart: always
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
      redis:
        condition: service_healthy
      clickhouse:
        condition: service_healthy
    ports:
      - "127.0.0.1:3030:3030"
    environment:
      # 基本設定
      NEXTAUTH_URL: ${NEXTAUTH_URL:-http://localhost:3000}
      DATABASE_URL: ${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres}
      SALT: ${SALT}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      # ClickHouse
      CLICKHOUSE_URL: ${CLICKHOUSE_URL:-http://clickhouse:8123}
      CLICKHOUSE_USER: ${CLICKHOUSE_USER:-clickhouse}
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
      # S3/MinIO (イベント・メディア保存)
      LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: ${MINIO_ENDPOINT:-http://minio:9000}
      LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: ${MINIO_ROOT_USER}
      LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: ${MINIO_ROOT_PASSWORD}
      LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT: ${MINIO_ENDPOINT:-http://minio:9000}
      LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID: ${MINIO_ROOT_USER}
      LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY: ${MINIO_ROOT_PASSWORD}
      # Redis
      REDIS_HOST: ${REDIS_HOST:-redis}
      REDIS_PORT: ${REDIS_PORT:-6379}
      REDIS_AUTH: ${REDIS_AUTH}
      # Langfuse 初期化 (オプション)
      LANGFUSE_INIT_ORG_ID: ${LANGFUSE_INIT_ORG_ID}
      LANGFUSE_INIT_ORG_NAME: ${LANGFUSE_INIT_ORG_NAME}
      LANGFUSE_INIT_PROJECT_ID: ${LANGFUSE_INIT_PROJECT_ID}
      LANGFUSE_INIT_PROJECT_NAME: ${LANGFUSE_INIT_PROJECT_NAME}
      LANGFUSE_INIT_PROJECT_PUBLIC_KEY: ${LANGFUSE_INIT_PROJECT_PUBLIC_KEY}
      LANGFUSE_INIT_PROJECT_SECRET_KEY: ${LANGFUSE_INIT_PROJECT_SECRET_KEY}
      LANGFUSE_INIT_USER_EMAIL: ${LANGFUSE_INIT_USER_EMAIL}
      LANGFUSE_INIT_USER_NAME: ${LANGFUSE_INIT_USER_NAME}
      LANGFUSE_INIT_USER_PASSWORD: ${LANGFUSE_INIT_USER_PASSWORD}
      # NextAuth (langfuse-web用の追加)
      NEXTAUTH_SECRET: ${NEXTAUTH_SECRET}
      TELEMETRY_ENABLED: ${TELEMETRY_ENABLED:-true}
    networks:
      - langfuse_net

  langfuse-web:
    image: docker.io/langfuse/langfuse:3
    restart: always
    depends_on:
      - langfuse-worker
    ports:
      - "3000:3000"
    environment:
      <<: *langfuse-worker_env
      # langfuse-worker と共通の環境変数を継承
      NEXTAUTH_SECRET: ${NEXTAUTH_SECRET}
    networks:
      - langfuse_net

  clickhouse:
    image: docker.io/clickhouse/clickhouse-server
    restart: always
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: ${CLICKHOUSE_USER:-clickhouse}
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
    volumes:
      - clickhouse_data:/var/lib/clickhouse
      - clickhouse_logs:/var/log/clickhouse-server
    ports:
      - "127.0.0.1:8123:8123"
      - "127.0.0.1:9000:9000"
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q http://localhost:8123/ping || exit 1"]
      interval: 5s timeout: 5s retries: 5

  minio:
    image: cgr.dev/chainguard/minio
    restart: always
    entrypoint: sh
    command: -c "mkdir -p /data/langfuse && minio server --address \":9000\" --console-address \":9001\" /data"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    ports:
      - "9090:9000"   # S3互換API
      - "127.0.0.1:9091:9001"  # MinIOコンソール
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "alias", "set", "local", "http://localhost:9000", "${MINIO_ROOT_USER}", "${MINIO_ROOT_PASSWORD}"]
      interval: 3s timeout: 5s retries: 3

  redis:
    image: docker.io/redis:7
    restart: always
    command: >
      --requirepass ${REDIS_AUTH}
      --maxmemory-policy noeviction
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s timeout: 10s retries: 5

  postgres:
    image: docker.io/postgres:17
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB:-postgres}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s timeout: 3s retries: 5

volumes:
  postgres_data:
  clickhouse_data:
  clickhouse_logs:
  minio_data:
  redis_data:

networks:
  langfuse_net:
    driver: bridge
```

```dotenv
# .env テンプレート例 (.gitignore登録推奨)
# Dockerイメージ/バージョン
POSTGRES_VERSION=17
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_PASSWORD=clickhouse

# データベース
POSTGRES_USER=postgres
POSTGRES_PASSWORD=StrongPostgresPass  # CHANGEME
POSTGRES_DB=postgres

# MinIO (S3互換)
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=StrongMinioPass  # CHANGEME

# Redis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_AUTH=StrongRedisPass  # CHANGEME

# Langfuse初期設定 (任意)
LANGFUSE_INIT_ORG_ID=my-org
LANGFUSE_INIT_ORG_NAME="My Organization"
LANGFUSE_INIT_PROJECT_ID=my-project
LANGFUSE_INIT_PROJECT_NAME="My Project"
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-abc123
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-def456
LANGFUSE_INIT_USER_EMAIL=admin@example.com
LANGFUSE_INIT_USER_NAME="Administrator"
LANGFUSE_INIT_USER_PASSWORD=SuperSecretPass

# Langfuse認証
NEXTAUTH_SECRET=AnotherSecretValue
SALT=RandomSaltValue1234
ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# Langfuse SDK用 (必要に応じて設定)
LANGFUSE_BASE_URL=http://localhost:3000
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

```mermaid
flowchart TD
  A[アプリケーション(Claude Code)] -->|LLM呼び出し| B[Claudeモデル]
  B -->|応答 + 使用量| C[Langfuseトレース]
  C -->|usage_details| D[コスト計算]
  D -->|cost_details| E[ダッシュボード表示]
```

*（上図：モデル呼び出しからトレース生成・使用量計測→コスト算出→ダッシュボードへの流れ）*

