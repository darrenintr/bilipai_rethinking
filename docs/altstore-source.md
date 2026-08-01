# AltStore / SideStore 自訂源

Paladala 透過 GitHub Actions 自動將最新嘅 unsigned IPA 發佈為 AltSource。
只要你將以下 URL 加入 AltStore / SideStore 嘅「自訂源」,就可以喺 App 內直接睇到最新版本、安裝、續簽,再唔使每次都去 Releases 頁手動下載。

## 源 URL

```
https://darrenintr.github.io/pure-bilibili-rethinking/apps.json
```

呢個 URL 由 GitHub Pages 服務,GitHub Actions 會喺每次 push 到 `working` 分支、產出新 prerelease 之後,自動更新背後嗰份 `apps.json`。

## 一次性設定(只係第一次需要做)

### 1. 開啟 GitHub Pages

1. 去 https://github.com/darrenintr/pure-bilibili-rethinking/settings/pages
2. **Build and deployment → Source**: 揀 **Deploy from a branch**
3. **Branch**: 揀 **`gh-pages`** / **`/(root)`**
4. 撳 **Save**

> GitHub 會花大約 30 秒到 1 分鐘簽發首次部署。完成後會見到一個網址
> `https://darrenintr.github.io/pure-bilibili-rethinking/`。

### 2. 確認 `apps.json` 已經喺度

用瀏覽器開

```
https://darrenintr.github.io/pure-bilibili-rethinking/apps.json
```

應該會見到一個合法嘅 JSON,內有 `name`、`bundleIdentifier`、`versions` 等欄位。
如果係 404,代表第一次 push 仲未觸發 — 喺「Actions」頁面手動 re-run 一次 `iOS Unsigned IPA` workflow 即可。

## 喺 AltStore / SideStore 裡加入

| 步驟 | 操作 |
| --- | --- |
| 1 | 開 AltStore / SideStore,去 **Sources** tab |
| 2 | 撳左上角嘅 **+** |
| 3 | 貼上 `https://darrenintr.github.io/pure-bilibili-rethinking/apps.json` |
| 4 | 撳 **Add Source**(或者名你鍾意) |

之後 Paladala 會出現喺 Sources 清單裡,撳入去就見到可安裝版本,再撳 **Install** 就可以自動下載 + 簽名 + 安裝。

## 之後點樣運作

- 每次 push 到 `working` 分支,GitHub Actions 會跑 `iOS Unsigned IPA` workflow
- 流程會:
  1. 構建 unsigned IPA
  2. 開一個 prerelease Release
  3. 更新 `apps.json` 並 push 到 `gh-pages` 分支
- 喺 AltStore / SideStore 重新整理 source,就會見到新版本

整個過程對你嚟講係 **零操作** — push 完 code 之後就自動有得裝。

## 如果出咗問題

| 症狀 | 可能原因 | 點解決 |
| --- | --- | --- |
| `apps.json` 404 | GitHub Pages 未開 / 第一次 deploy 未完成 | 跟「一次性設定」步驟 1 開 Pages,等 1 分鐘再試 |
| AltStore 見唔到 Paladala | 源 URL 串錯 / 個 JSON 壞咗 | 開 https://darrenintr.github.io/pure-bilibili-rethinking/apps.json 喺瀏覽器,確認係合法 JSON |
| AltStore 見到 App 但裝唔到 | IPA download URL 失效 | 開 JSON 揾 `versions[0].downloadURL` 喺瀏覽器試下載,確認 Releases 頁仲有對應 tag |
| SideStore 連加都加唔到 | `iconURL` 喺 iOS 載唔到(必須係 PNG/JPG,SVG 唔得) | 確認 `iconURL` 係 `.png`;workflow 而家已經會 render PNG |
| AltStore 標題有但係見唔到 App | Settings → 開咗「安裝未簽名 App」未? | AltStore 入 Settings → 開 "Install Unauthorized Apps"(需要開發者模式) |

## 想自己改 apps.json 嘅 metadata?

唔需要改 workflow。打開 `scripts/generate_apps_json.py`,最頂嘅 `APP_META` dict 改你想改嘅欄位(`subtitle`、`tintColor`、`localizedDescription` 等),跟住 push 一次就會喺下次 build 自動生效。
