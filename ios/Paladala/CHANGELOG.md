# Paladala for iOS — Changelog

## v0.5.1 (2026-07-06)

`CFBundleShortVersionString` bumped from `0.5.0 TESTING` → `0.5.1`.
Iteration release on the v0.5 line.

### Home grid spacing rework

- **Card-to-card gaps widened.** `GridItem` inter-column spacing
  `12 → 28`, minimum column width `156 → 146` (keeps 2 columns on
  iPhone SE with the wider gap). `LazyVGrid` inter-row spacing
  `18 → 22` for both the video grid and the live-room grid.
- **Top padding inside `VideoCard`** — `.padding(.top, 8)` so the
  thumbnail has breathing room from the card's top edge (previously
  flush with the card surface by design).
- **Cover image pinned to 16:10.** `frame(maxWidth:.infinity)` +
  `aspectRatio(16/10, .fill)` + `clipped`. Every thumbnail now
  occupies the exact same bounding box regardless of source aspect
  ratio (16:9, 4:3, 1:1 all get scaled to fill and cropped).
  Combined with `maxWidth:.infinity` on the title / owner / counts
  rows, every card in a row has the same height — the grid no longer
  wobbles.
- **Cover corner radius matches the card.** Re-applied
  `clipShape(RoundedRectangle(cardRadius))` to the cover now that
  it sits 8pt inside the card (the card-level clip no longer reaches
  it). The two share the same 24pt curve.

### B 站 coin (硬币) support

- **Coin balance chip** in the signed-in profile header. Loads
  alongside the follow / fan / dynamic stats from
  `/site/getCoin` (`data.money`).
- **投币 (give coins) action** in the video context menu — a
  "投币支持 UP 主" submenu offering 1 or 2 coins per video,
  hitting `/x/web-interface/coin/add` with auto-extracted CSRF.
  Upstream rejection reasons (硬币余额不足, 超过投币上限) are
  surfaced to the user.

### App identity hardening

- The personalised app recommendation feed (`/x/v2/feed/index`)
  and the story / reels feed now include the official iOS client
  `build` number (`84900100`) in the signed query. Verified live:
  10 vs 8 items on the same account, better algorithm ranking.

### CI

- `ios-unsigned-ipa.yml` now derives the prerelease tag from
  `CFBundleShortVersionString`, so bumping the marketing version
  in `Info.plist` automatically rolls the tag forward (e.g.
  `0.5.1` → `v0.5.1.N` instead of always being `v0.4.N`).
  Old `v0.4.*` / `v0.3-alpha-ios-*` tag patterns are still
  recognised so the monotonic build counter does not reset.

## v0.5.0 BETA (2026-07-04)

`CFBundleShortVersionString` bumped from `0.4 BETA` → `0.5.0 BETA`,
`CFBundleVersion` `1` → `2`. This release focuses on
**animation polish** across the app and a major expansion of
the **UP personal page** (sub-tabs, follow / unfollow, share
menu, public favorites, UP's own dynamic posts).

### UP 个人主页大改版

- **关注 / 取消关注** — `UPProfileView` header now ships a
  follow button that calls `/x/relation` for the current
  relation and `/x/relation/modify` (POST with `act=1` /
  `act=2` and the cookie's CSRF) for the toggle. Optimistic
  UI flip + spring scale animation + a "已关注" / "已取消关注"
  toast. Signed-out users see a "关注" CTA that opens the
  login sheet on tap.
- **三标签分页** — 投稿 / 动态 / 收藏 segmented picker
  replaces the single 投稿 section. The active tab is
  persisted in `@AppStorage("paladala.upProfileTab")` so a
  relaunch restores the user's last choice.
- **动态 tab** — calls
  `/x/polymer/web-dynamic/v1/space/space_brief?host_mid`
  with `offset` pagination. Lazy-loaded the first time the
  tab opens; loads more as the user scrolls to the bottom.
- **收藏 tab** — calls
  `/x/v3/fav/folder/created/list-all?up_mid` to list the
  UP's public favorite folders. Tapping a row pushes
  `FavoriteFolderVideosView` (the same view the
  signed-in user's own favorites use) via a new
  `ProfileRoute.favoriteFolder(FavoriteFolderSummary)`
  case.
- **分享菜单** — toolbar trailing `.menu` with ShareLink
  (`https://space.bilibili.com/<mid>`), copy UID to
  clipboard, and open in browser.
- **关注入口** — `BiliRelation` enum with `.notRelated` /
  `.followed` / `.silentFollow` / `.blocked` cases.
- **粉丝 / 关注 标签** — 动态 stat pill is now a tap
  target that switches to the `.dynamics` tab via a spring
  animation. 粉丝 and 关注 stay inert (Bilibili's public
  followers / followings list endpoints need the signed-in
  user's cookie and return a different shape; deferred to
  v0.6).
- **ProfileRoute 新增** — `.favoriteFolder(FavoriteFolderSummary)`
  case alongside the existing `.favorites(mid:)` so the
  destination view is selectable per-folder rather than
  per-user.

### 动画

- **骨架屏 shimmering** — new `.paladalaShimmer()` modifier
  sweeps a translucent gradient across placeholder rects
  in a 1.4 s loop, masked to the underlying content so the
  highlight only paints inside the rounded rectangles.
  Applied to `SkeletonCard`, `DynamicFeedSkeletonRow`, the
  UP profile header / row / dynamic-row / folder-row
  skeletons. Honours Reduce Motion (no animation when
  accessibility reduce-motion is on).
- **UP 入口卡 slide-in** — `VideoDetailView`'s `upEntryCard`
  transitions from `.opacity` to
  `.move(edge: .top).combined(with: .opacity)` so when the
  card mounts it slides in from the top instead of fading.
- **首屏 stagger fan-in** — `HomeViewModel` gains a
  `firstPageAnimated` bool that flips `false → true` once
  on the first successful load. The grid cards then fade
  in with a 0.035 s × index stagger (capped at index 12)
  and a 12 pt slide. Re-loads / category switches skip
  the animation.
- **Press-bounce buttons** — `PaladalaPressBounceButtonStyle`
  scales the label to 0.92 on press with a
  `.spring(response: 0.18, dampingFraction: 0.6)`, releases
  with a softer `.spring(response: 0.32, dampingFraction: 0.7)`.
  Applied to `VideoCard`, `LiveRoomCard`, the comment like
  button, the UP profile follow button, the UP-published
  video row, the UP favorite folder row, and the dynamic
  card rows.
- **Liquid-Glass sheet backgrounds** —
  `.paladalaSheetGlass()` modifier applies
  `.presentationBackground(.regularMaterial)` +
  `.presentationCornerRadius(28)` to sheets. Applied to
  `LoginSheet`; the future follow-confirm sheet and
  diagnostic share sheet will use the same modifier.

### Models / API additions

- `BiliRelation` enum in `Models.swift` —
  `attribute` → `BiliRelation` mapping with
  `isFollowing` convenience accessor.
- `BilibiliAPIClient.userRelation(target:selfMid:)` —
  GET `/x/relation`.
- `BilibiliAPIClient.modifyRelation(target:act:)` —
  POST `/x/relation/modify` with the cookie's `bili_jct`
  as `csrf`.
- `BilibiliAPIClient.userDynamic(hostMid:offset:)` —
  GET `/x/polymer/web-dynamic/v1/space/space_brief`.
- `BilibiliAPIClient.userFavoriteFolders(upMid:)` —
  GET `/x/v3/fav/folder/created/list-all?up_mid`.
- `PaladalaRepository` thin wrappers for all four.
- Internal DTOs `RelationAttributePayload`,
  `ModifyRelationPayload`, `UserFavoriteFoldersPayload`,
  `UserFavoriteFolderDTO`.

### Memory

- `ios-app-paladala-v0.5-2026-07-04.md` — what landed and
  what was deferred.