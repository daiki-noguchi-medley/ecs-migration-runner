# Windows でのセットアップガイド

このプロジェクトは Windows / macOS / Linux 全環境で動作します。

## クイックスタート（Windows 推奨フロー）

### 1️⃣ 前提条件

以下をインストール：
- [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop)
- [VSCode](https://code.visualstudio.com/) + Dev Containers 拡張機能
- [Git for Windows](https://gitforwindows.org/)

### 2️⃣ リポジトリをクローン

```powershell
# PowerShell または Git Bash で
git clone https://github.com/daiki-noguchi-medley/ecs-migration-runner.git
cd ecs-migration-runner
```

### 3️⃣ Dev Container を起動（推奨）

```powershell
# VSCode で開く
code .

# VSCode のコマンドパレット (Ctrl+Shift+P) で以下を実行
Dev Containers: Open Folder in Container
```

または `make` を使用：

```powershell
# WSL2 がある場合
wsl make devcontainer-up

# 直接 docker-compose を使用する場合
docker compose -f .devcontainer/docker-compose.yml up -d
```

### 4️⃣ Dev Container 内で開発

```bash
# Dev Container のターミナルで（自動的に起動します）

# SQL をフォーマット
make gradle-fix

# 動作確認
make info
make psql
```

---

## モード別セットアップ

### モード A: ローカル Compose（シンプル）

**要件**: Docker Desktop のみ（Gradle は不要）

```powershell
# PowerShell で
docker compose up -f docker-compose.yml up --abort-on-container-exit flyway

# または make で（WSL2 必要）
wsl make up
```

**制限**: SQL フォーマット（Spotless）はローカル Gradle が必要

---

### モード B: Dev Container（推奨）

**要件**: Docker Desktop + VSCode + Dev Containers 拡張

```powershell
# VSCode で以下のコマンドを実行
Dev Containers: Open Folder in Container
```

**利点**:
- ✅ Java / Gradle をインストール不要
- ✅ PostgreSQL + Flyway + Spotless が全部入り
- ✅ Mac と 100% 同じ環境

---

## WSL2 で make コマンドを使う（オプション）

Windows に `make` をインストールして使いたい場合（推奨しません、Dev Container 使用推奨）：

### 方法 1: WSL2 + Ubuntu（推奨）

```powershell
# PowerShell で WSL2 を有効化
wsl --install

# Ubuntu を起動してセットアップ
wsl

# Ubuntu 内で
sudo apt update
sudo apt install make

# ここから make コマンドが使える
make up
```

### 方法 2: Git Bash（簡単だが環境依存）

1. [Git for Windows](https://gitforwindows.org/) をインストール
2. インストーラで `make` を選択
3. Git Bash を開く
4. `make up` で実行

---

## よくあるトラブル

### Q1: `make: command not found` が出た

**回答**: 
- **推奨**: Dev Container を使用 (`make devcontainer-up`)
- **代替**: WSL2 で `make` をインストール
- **代替**: `docker compose` コマンド直接実行

```powershell
# WSL2 がない場合、docker compose 直接実行
docker compose -f docker-compose.yml up --abort-on-container-exit flyway
```

### Q2: Docker Desktop が起動しない

```powershell
# Docker Desktop の再起動
# または WSL2 を再初期化
wsl --shutdown
wsl
```

### Q3: Dev Container が起動しない

```powershell
# Docker イメージを再ビルド
docker compose -f .devcontainer/docker-compose.yml down -v
code .
# VSCode で再度 "Dev Containers: Open Folder in Container"
```

### Q4: PostgreSQL のポートが既に使用中

```powershell
# ポート 5432 を使用しているプロセスを確認
netstat -ano | findstr :5432

# または Docker volume をリセット
docker compose -f docker-compose.yml down -v
```

---

## パワーシェル vs Git Bash

| 機能 | PowerShell | Git Bash |
|-----|-----------|----------|
| `docker compose` | ✅ | ✅ |
| `make` | ❌ (WSL2 必要) | ✅ (インストール時) |
| Dev Containers | ✅ | ✅ |
| **推奨度** | ⭐⭐⭐ | ⭐⭐ |

**推奨**: PowerShell + Dev Container

---

## 参考リンク

- [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/)
- [VSCode Dev Containers](https://code.visualstudio.com/docs/devcontainers/containers)
- [WSL2 セットアップ](https://learn.microsoft.com/ja-jp/windows/wsl/install)
