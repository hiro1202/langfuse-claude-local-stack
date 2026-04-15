# langfuse-claude-local-stack

Claude Code の会話トレースをローカルの [Langfuse](https://langfuse.com/) に送る、「中身が全部見える」スターター。
6 ファイル・約 360 行（10 分で全部読める量）。bash + curl + jq のみ。Python / Node.js 依存なし。

## このリポジトリの方針

- **Glass-Box（透明な箱）**: 全コードを 10 分で読み切れる量。何が送信されるか自分の目で確認できる。
- **依存パッケージゼロ**: pip / npm を使わない。サプライチェーン攻撃のリスクを最小化。
- **公式イメージのみ**: Docker は Langfuse 公式イメージと Postgres / ClickHouse / Redis / MinIO の公式イメージだけ。
- **localhost 専用**: 全ポートを `127.0.0.1` にバインド。外部からアクセス不可。
- **学習・検証用**: 失敗は静かに諦める fail-open 設計。重複送信の防止やリトライは実装していない。本番オブザーバビリティ用途には追加実装が必要。

## 必要なもの

- macOS / Linux（Windows は WSL2 経由）
- Docker Engine 24+ と Docker Compose V2（`docker compose` サブコマンド）
- `jq`, `openssl`, `curl`（macOS は `brew install jq`、Debian/Ubuntu は `apt-get install jq`）
- [Claude Code](https://docs.claude.com/en/docs/claude-code) がインストール済み

## セットアップ（3 コマンド）

```bash
git clone https://github.com/hiro1202/langfuse-claude-local-stack.git
cd langfuse-claude-local-stack
./setup.sh
docker compose up -d
```

これで以下が起動します:

| URL | 用途 |
|-----|------|
| http://localhost:3050 | Langfuse Web UI |
| http://localhost:9091 | MinIO コンソール（オブジェクトストレージ） |

ログイン情報は `credentials.txt`（`chmod 600`、`.gitignore` 済み）に書き出されます。
ターミナル履歴に残さないよう画面表示しません。

```bash
cat credentials.txt
```

初回起動後、Langfuse UI にログインできるか確認してください。

## 動作確認

### 1. DRY_RUN モードで送信内容を確認

Langfuse に実際に送らず、送信予定の JSON を stderr に出力します。
「何が送信されるか」を自分の目で確認できます。

```bash
DRY_RUN=1 claude
# → 会話を 1 ターン実行後、Stop フックが発火し、
#    [langfuse-hook] DRY_RUN=1 — payload follows (not sent):
#    { ...JSON... }
#    がターミナルに表示される
```

### 2. 通常モードで Langfuse に送信

```bash
claude
# 会話後、http://localhost:3050 のダッシュボードに trace が表示される
```

### 3. デバッグ

hook が静かに何かをスキップしている場合は stderr を見てください。

```bash
claude 2>&1 | grep '\[langfuse-hook\]'
```

## データフロー

```
 ┌───────────────┐     ┌───────────────────────┐     ┌──────────────────┐
 │  Claude Code  │──→  │ hooks/send-to-langfuse│──→ │ Langfuse (local) │
 │ (Stop hook)   │     │   .sh (bash+curl+jq)  │     │   :3050          │
 └───────────────┘     └───────────────────────┘     └──────────────────┘
         │                        │                           │
         │ stdin JSON             │ POST /api/public/         │
         │ {session_id,           │  ingestion                │
         │  transcript_path}      │ (Basic Auth)              │
         ▼                        ▼                           ▼
  ~/.claude/projects/      latest user + assistant     Postgres + ClickHouse
  .../<session>.jsonl      text from transcript         + MinIO
```

## ファイル構成

```
langfuse-claude-local-stack/
├── docker-compose.yml       # 6 サービス（langfuse-web/worker, postgres, clickhouse, redis, minio）
├── .env.example             # 環境変数テンプレート
├── .gitignore               # .env, credentials.txt を除外
├── hooks/
│   └── send-to-langfuse.sh  # Claude Code Stop フック本体
├── setup.sh                 # .env 生成 + フック登録
└── README.md                # このファイル
```

## 環境変数（`.env`）

`setup.sh` が `openssl rand` で自動生成します。手動で書き換える必要はありません。

| 変数 | 用途 |
|------|------|
| `POSTGRES_PASSWORD` | PostgreSQL |
| `CLICKHOUSE_PASSWORD` | ClickHouse |
| `REDIS_AUTH` | Redis |
| `MINIO_ROOT_PASSWORD` | MinIO |
| `NEXTAUTH_SECRET` | Langfuse セッション暗号化 |
| `ENCRYPTION_KEY` | Langfuse データ暗号化（32byte） |
| `SALT` | Langfuse ハッシュソルト |
| `LANGFUSE_INIT_PROJECT_PUBLIC_KEY` | Langfuse API 公開鍵（hook が使用） |
| `LANGFUSE_INIT_PROJECT_SECRET_KEY` | Langfuse API 秘密鍵（hook が使用） |
| `LANGFUSE_INIT_USER_EMAIL` | 管理者メール（デフォルト `admin@example.com`） |
| `LANGFUSE_INIT_USER_PASSWORD` | 管理者パスワード |

## アンインストール

```bash
# 1. コンテナとデータを削除
docker compose down -v

# 2. ~/.claude/settings.json から Stop フックを削除
jq 'del(.hooks.Stop[]? | select(.hooks[]?.command | test("langfuse-claude-local-stack")))' \
  ~/.claude/settings.json > ~/.claude/settings.json.tmp && \
  mv ~/.claude/settings.json.tmp ~/.claude/settings.json

# 3. リポジトリ削除
cd .. && rm -rf langfuse-claude-local-stack
```

## 既知の制限

学習・検証用として割り切っているため、以下は実装していません:

- **重複送信防止**: Stop フックが短時間に複数回発火すると同じ内容が複数回送られる可能性がある。
- **リトライ / キューイング**: Langfuse が停止中の場合は送信失敗が無視される（fail-open）。ログは失われる。
- **マルチセッション排他制御**: 複数の Claude Code セッションを同時実行すると競合し得る。
- **詳細トレース**: tool_use / tool_result の個別ステップは送信しない。最新の user 発話と assistant 応答のみ。

本番オブザーバビリティ用途では、[Langfuse 公式 SDK](https://langfuse.com/docs/sdk/overview) を使った実装を推奨します。

## 参考リンク

- [Langfuse 公式ドキュメント](https://langfuse.com/docs)
- [Langfuse セルフホスト（Docker Compose）](https://langfuse.com/self-hosting/docker-compose)
- [Langfuse Ingestion API](https://api.reference.langfuse.com/)
- [Claude Code Hooks](https://docs.claude.com/en/docs/claude-code/hooks)

## 謝辞

Docker 構成は [doneyli/claude-code-langfuse-template](https://github.com/doneyli/claude-code-langfuse-template) を参考にしました。本リポジトリは「全コードを自分で書き、読み切れる量に絞る」ことを目的にゼロから再実装したものです。

## ライセンス

MIT
