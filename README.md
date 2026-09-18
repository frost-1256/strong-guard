# Strong Guard

A KernelSU / Magisk module that keeps **Play Integrity `MEETS_STRONG_INTEGRITY`** alive on a rooted device by automatically keeping the keystore **keybox** fresh.

> [!WARNING]
> **Personal project — use at your own risk.**
> This module was written by an individual for their own device, with the help of AI coding tools. It is not an official or professionally maintained project. Review the code before flashing, and keep a backup.
>
> **AI-generated notice:** A large part of this module (scripts, WebUI, documentation) was produced with AI assistance. Expect mistakes.
>
> This module spoofs device attestation for Play Integrity. That may violate Google's Terms of Service and **can stop working at any time** (keybox revocation, server-side changes, API changes). No warranty, no support, no responsibility for anything that happens to your device, data, or accounts.

## Features

- **Health monitoring** — validates keybox structure, certificate expiry, and Google's attestation revocation list (`android.googleapis.com/attestation/status`).
- **Real verdict checks** — periodically drives the *Play Integrity API Checker* app via `uiautomator` and reads the actual BASIC / DEVICE / STRONG verdicts (only while the screen is on and unlocked).
- **Automatic recovery** — when the keybox is revoked, expiring, or failing, it fetches a fresh keybox from public sources, validates it on device, installs it atomically, confirms the hot-reload, clears DroidGuard caches, re-checks the verdict, and **rolls back automatically** if anything goes wrong.
- **On-device validation** — certificate parsing (serial / notBefore / notAfter) is done with a tiny pure-`awk` DER parser; no `openssl` required.
- **Verified Boot hash sync** — keeps OhMyKeymint's attested `verifiedBootHash` equal to the system `ro.boot.vbmeta.digest`, so KeyAttestation-style apps don't flag a “Verified Boot hash mismatch”.
- **EC + RSA merge** — adapts keyboxes to spoofers that require both chains (e.g. OhMyKeymint).
- **Material 3 WebUI** with Japanese / English switching.
- Works with **OhMyKeymint** (primary) and **TrickyStore** (if installed).

## Requirements

- **Android 12 or higher** (OhMyKeymint / TrickyStore requirement; KeyMint / keystore2).
- **Root:** KernelSU / ReSukiSu (or Magisk). A WebUI-capable manager (KernelSU / ReSukiSu) is required for the WebUI.
- **A keystore spoofer**, either:
  - **OhMyKeymint** (recommended) — `/data/misc/keystore/omk/` must exist, GMS/GSF/Vending must be in its `scoop`, and the keybox must contain **both EC and RSA chains** (Strong Guard merges them automatically), or
  - **TrickyStore** — `/data/adb/tricky_store/keybox.xml` is updated as well when present.
- **Network access** to `raw.githubusercontent.com` (keybox sources) and `android.googleapis.com` (revocation list).
- **Play Integrity API Checker** (`gr.nikolasspyr.integritycheck`). Without it, verdict-based detection is unavailable and only the CRL / expiry checks run.
- **For verdict checks: screen on and unlocked.** Checks are skipped and retried later while locked.
- An initial valid keybox is helpful but not required — Strong Guard fetches one from its sources if needed.
- **Note:** Strong Guard only maintains the keybox and the verified-boot hash. Passing STRONG still requires a working fingerprint spoof (PIF) and your hiding stack (SUSFS / Shamiko / etc.).
- busybox is auto-detected (`/data/adb/ksu/bin/busybox`, `/data/adb/magisk/busybox`, `/data/adb/ap/bin/busybox`); the module degrades gracefully without it.

## How it works

1. **Health check** (every 60 min by default)
   - refreshes the revocation list,
   - checks every certificate in the active keybox (parse + expiry + revocation),
   - fetches fresh candidates if the last fetch is older than `FETCH_INTERVAL_H`.
2. **Verdict check** (every 24 h by default, when unlocked)
   - launches the checker app, taps **CHECK**, and reads the three verdict chips.
3. **Rotation** (on revoked / expiring / failing keybox)
   - tries candidates in order: `custom` → `meow` → `yuri` → vault,
   - validates each, merges EC + RSA if needed,
   - backs up the current keybox, installs atomically (`0600 keystore:keystore`) to OhMyKeymint and TrickyStore paths,
   - watches `keymint.log` to confirm the reload (`fallback=false`),
   - clears `/data/data/com.google.android.gms/app_dg_cache` + `app_dgp`, force-stops GMS / Play Store,
   - re-runs the verdict check (up to 3 attempts) and keeps the candidate only if STRONG passes,
   - otherwise restores the last known-good keybox.

A background daemon (`service.sh`, detached with `setsid`) runs the loop; `action.sh` and the WebUI call into the same code.

## Installation

```sh
git clone https://github.com/frost-1256/strong-guard
cd strong-guard
zip -r strong_guard.zip . -x '.git/*' -x 'README.md'
# then: KernelSU Manager → Modules → Install from local file → strong_guard.zip
```

Or copy manually (root shell):

```sh
cp -r strong-guard /data/adb/modules/strong_guard
chmod 755 /data/adb/modules/strong_guard/*.sh
reboot
```

Uninstalling through the manager stops the daemon (runtime data under `/data/adb/strong_guard/` is kept).

## Configuration

`/data/adb/strong_guard/config.conf` (created on first boot):

| Key | Default | Description |
|---|---|---|
| `CHECK_INTERVAL_MIN` | `60` | Health-check interval (minutes) |
| `FETCH_INTERVAL_H` | `12` | Minimum interval between source fetches (hours) |
| `VERDICT_INTERVAL_H` | `24` | Interval between Play Integrity verdict checks (hours) |
| `EXPIRY_WARN_DAYS` | `5` | Rotate proactively when the keybox expires within N days and a newer candidate exists |
| `AUTO_ROTATE` | `1` | Enable automatic recovery |
| `NOTIFY` | `1` | Post Android notifications on recovery / failure |
| `SYNC_VBHASH` | `1` | Sync OhMyKeymint `vb_hash` with `ro.boot.vbmeta.digest` (restarts OMK when it changes) |
| `SOURCES` | `meow yuri custom` | Candidate sources |

**Bring your own private keybox:** drop a keybox XML at `/data/adb/strong_guard/custom/keybox.xml`. It is used with the highest priority and is the most reliable option.

### CLI

```sh
sh /data/adb/modules/strong_guard/action.sh status   # summary
sh /data/adb/modules/strong_guard/action.sh check    # run a verdict check now
sh /data/adb/modules/strong_guard/action.sh rotate   # emergency rotation now
sh /data/adb/modules/strong_guard/action.sh fetch    # fetch sources
```

### WebUI

KernelSU Manager → **Strong Guard** → **WebUI**.
Shows the current verdicts, keybox expiry, daemon / spoofer status, and lets you fetch, re-check, rotate, toggle automation, and read the log. Language: 日本語 / English.

## Keybox sources

| Source | Notes |
|---|---|
| `custom` | Your own keybox file (recommended, never shared) |
| `meow` | [MeowDump/MeowDump](https://github.com/MeowDump/MeowDump) `Megatron` (rotated roughly weekly) |
| `yuri` | [Yurii0307/yurikey](https://github.com/Yurii0307/yurikey) `key` (legacy backup) |

Public/shared keyboxes are revoked or soft-banned in waves. The module recovers automatically as soon as a fresh keybox is available, **but no on-device tool can create a valid keybox out of thin air** — if every source is dead or revoked, STRONG stays down until a new one is published. A private, unshared keybox is the most durable option.

## Troubleshooting

### KeyAttestation-style apps report “Verified Boot hash mismatch”

Some devices never pass `ro.boot.vbmeta.digest` from the bootloader. OhMyKeymint's `vb_hash = "auto"` then falls back to a **random** hash while the hiding modules set the property later, so the attestation record and the system property disagree.

Strong Guard fixes this automatically: after boot and on every health check it writes the current `ro.boot.vbmeta.digest` into `/data/misc/keystore/omk/config.toml` (`[trust] vb_hash = "<64 hex>"`) and restarts OMK. Manual equivalent:

```sh
prop=$(getprop ro.boot.vbmeta.digest)
sed -i "s|^vb_hash = .*|vb_hash = \"$prop\"|" /data/misc/keystore/omk/config.toml
touch /data/adb/omk/restart.all
```

After an OMK restart Play Integrity may keep failing for a few minutes (GMS negative caching); it recovers on its own.

## Files

```
module.prop          module metadata
lib.sh               core logic (validation, CRL, rotation, install, verdict)
service.sh           boot daemon
action.sh            CLI / KernelSU action button
webui.sh             WebUI backend (info / actions / config)
post-fs-data.sh      runtime directories + default config
uninstall.sh         stops the daemon
bin/derparse.awk     DER certificate parser (serial / notBefore / notAfter)
bin/ymd2epoch.awk    UTC date → epoch
bin/hex2dec.awk      big integer hex → decimal (revocation list matching)
webroot/index.html   Material 3 WebUI (JA / EN)
```

## Credits

- [MeowDump / Integrity Box](https://github.com/MeowDump/Integrity-Box) — keybox source and ecosystem inspiration
- [Yurii0307/yurikey](https://github.com/Yurii0307/yurikey)
- [qwq233/OhMyKeymint](https://github.com/qwq233/OhMyKeymint), [5ec1cff/TrickyStore](https://github.com/5ec1cff/TrickyStore)
- [vvb2060/KeyAttestation](https://github.com/vvb2060/KeyAttestation)
- `gr.nikolasspyr.integritycheck` — Play Integrity API Checker

## License

No license has been chosen for this personal project yet. Until one is added, all rights are reserved by the author. If you plan to reuse or redistribute this code, open an issue first.

---

# Strong Guard（日本語）

**Play Integrity の `MEETS_STRONG_INTEGRITY` を維持するための KernelSU / Magisk モジュールです。** ルート化端末の keybox を監視し、失効・期限切れ・判定失敗を検知すると自動で新しい keybox を取得・検証・適用します。

> [!WARNING]
> **個人制作モジュール — 完全に自己責任で使用してください。**
> このモジュールは個人が自分の端末向けに、**AI生成ツールの支援を受けて**作成したものです（スクリプト・WebUI・ドキュメントの多くがAI生成を含みます）。バグや誤動作が含まれる可能性があります。導入前にコードを確認し、バックアップを取ってください。
>
> Play Integrity の attestation をスプーフィングするため、Google の利用規約に抵触する可能性があり、**予告なく動作しなくなることがあります**。端末・データ・アカウントへのいかなる損害についても責任を負いません。

## 主な機能

- keybox の構造・証明書期限・Google失効リスト（`attestation/status`）を定期チェック
- Play Integrity API Checker アプリを `uiautomator` 経由で操作し、**実際の BASIC / DEVICE / STRONG 判定**を定期取得（画面ロック・消灯中はスキップ）
- 異常検知時は公開ソースから新しい keybox を取得 → 端末内で検証（純 `awk` 製 DER パーサ）→ EC/RSA をマージ → バックアップ後に原子的に適用 → ホットリロード確認 → DroidGuard キャッシュ削除 → 再判定 → **失敗時は自動ロールバック**
- **Verified Boot hash の自動同期** — OhMyKeymint が attestation に載せる `verifiedBootHash` をシステムの `ro.boot.vbmeta.digest` に一致させ、KeyAttestation 系アプリの「Verified Boot hash mismatch」を防ぎます
- Material 3 の WebUI（日本語 / English 切替）
- **OhMyKeymint** を主対象、**TrickyStore** があれば併せて更新

## 必要なもの

- **Android 12 以上**（OhMyKeymint / TrickyStore の要件。KeyMint / keystore2 が必要）
- **root**: KernelSU / ReSukiSu（または Magisk）。WebUI利用にはWebUI対応マネージャー（KernelSU / ReSukiSu）が必要
- **キーストアスプーファー**（いずれか）
  - **OhMyKeymint**（推奨）: `/data/misc/keystore/omk/` が存在し、GMS/GSF/Vending が `scoop` に入っていること。keyboxは**ECとRSAの両方**が必要（Strong Guardが自動マージ）、または
  - **TrickyStore**: インストール済みなら `/data/adb/tricky_store/keybox.xml` も更新
- **ネットワーク**: `raw.githubusercontent.com`（keybox取得）と `android.googleapis.com`（失効リスト）
- **Play Integrity API Checker**（`gr.nikolasspyr.integritycheck`）。無い場合はCRL・期限切れベースのみで動作
- **判定チェック実行時は画面オン＋ロック解除が必要**（ロック中はスキップし、後で再試行）
- 初期keyboxは無くてもOK（ソースから取得します）
- **注意**: Strong Guard は keybox と vb_hash の維持のみを担当します。STRONGを通すには別途 **PIF等の指紋スプーフ** と **SUSFS / Shamiko 等の隠蔽スタック** が必要です
- busyboxは自動検出（`/data/adb/ksu/bin/busybox`、`/data/adb/magisk/busybox`、`/data/adb/ap/bin/busybox`）。無くても簡易動作します

## 導入

```sh
git clone https://github.com/frost-1256/strong-guard
cd strong-guard
zip -r strong_guard.zip . -x '.git/*' -x 'README.md'
# KernelSU マネージャー → モジュール → ローカルからインストール → strong_guard.zip
```

## 設定

`/data/adb/strong_guard/config.conf`（初回起動時に生成）

- `CHECK_INTERVAL_MIN`（60）: ヘルスチェック間隔（分）
- `FETCH_INTERVAL_H`（12）: ソース取得の最小間隔（時間）
- `VERDICT_INTERVAL_H`（24）: 判定チェック間隔（時間）
- `EXPIRY_WARN_DAYS`（5）: 期限切れが近く、より新しい候補がある場合に事前ローテーション
- `AUTO_ROTATE`（1）: 自動回復の有効/無効
- `NOTIFY`（1）: 回復・失敗時の通知
- `SYNC_VBHASH`（1）: OhMyKeymint の `vb_hash` を `ro.boot.vbmeta.digest` に同期（変更時はOMKを再起動）
- `SOURCES`（`meow yuri custom`）: 候補ソース

**私有 keybox を使う場合:** `/data/adb/strong_guard/custom/keybox.xml` に置くと最優先で使われます（最も確実です）。

## CLI / WebUI

```sh
sh /data/adb/modules/strong_guard/action.sh status|check|rotate|fetch
```

WebUI は KernelSU マネージャー → Strong Guard → **WebUI** から。

## できること・できないこと

公開 keybox は定期的に失効・ソフトBANされるため、ソースが生きている限りは自動回復できます。ただし**端末側だけで有効な keybox を新規生成することは原理的に不可能**です。全ソースが失効・配布停止した場合は、新しい keybox が公開されるまで STRONG は通りません。**非公開のkeyboxを `custom` に置くのが最も確実**です。

## トラブルシューティング

### KeyAttestation系アプリで「Verified Boot hash mismatch」

ブートローダーが `ro.boot.vbmeta.digest` を渡さない端末では、OhMyKeymint の `vb_hash = "auto"` が**ランダム値にフォールバック**し、後からモジュールが設定する prop と食い違います。

Strong Guard は起動時と1時間ごとに prop の値を `/data/misc/keystore/omk/config.toml` の `[trust] vb_hash` に書き込み、OMKを再起動して自動修正します。手動の場合:

```sh
prop=$(getprop ro.boot.vbmeta.digest)
sed -i "s|^vb_hash = .*|vb_hash = \"$prop\"|" /data/misc/keystore/omk/config.toml
touch /data/adb/omk/restart.all
```

OMKの再起動直後はGMSのネガティブキャッシュで数分Failすることがありますが、自然に回復します。

## クレジット

- [MeowDump / Integrity Box](https://github.com/MeowDump/Integrity-Box)（keybox 配布元）
- [Yurii0307/yurikey](https://github.com/Yurii0307/yurikey)
- [qwq233/OhMyKeymint](https://github.com/qwq233/OhMyKeymint), [5ec1cff/TrickyStore](https://github.com/5ec1cff/TrickyStore)
- [vvb2060/KeyAttestation](https://github.com/vvb2060/KeyAttestation)
- Play Integrity API Checker (`gr.nikolasspyr.integritycheck`)

## ライセンス

現時点で未設定の個人プロジェクトです。再利用・再配布を希望する場合は issue で相談してください。
