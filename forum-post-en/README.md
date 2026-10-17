# forum-post-en — 英文版 OBS 论坛发帖包

目标是 obsproject.com 的 **Resources → Scripts** 区。里面每一份都是可直接粘贴的成品，
不用再翻译、改写或补图。

---

## 一、文件清单

| 文件 | 用途 | 粘贴到哪 |
|---|---|---|
| `01-resource-listing-en.bbcode.txt` | 资源页正文（XenForo BBCode，图片走 raw 直链，打开就能显示） | Resources → Add resource → Description |
| `01-resource-listing-en.md` | 同一份内容的 Markdown 版 | GitHub README / 文档站 / 备份 |
| `02-thread-post-en.md` | 独立帖版本，第一人称讲「为什么做这个」，比资源页更像人写的 | 论坛 Scripts 子版块发新帖 |
| `03-resource-meta-en.md` | 表单字段：标题备选、tag line、分类、版本、标签、上传选项，外加提交前五分钟自检和预设回复 | 对着表单逐项抄 |
| `04-short-blurbs-en.md` | 短文案：一句话简介、GitHub About、X 单条/串推、Reddit r/obs、Discord、YouTube 简介 | 各平台直接贴 |
| `images/` | 九张截图，按上传顺序命名 | 想自己传附件时用 |

`01` 的 BBCode 版里图片是 `raw.githubusercontent.com` 直链，**不用上传附件**就能显示。
如果你更想让图片挂在本站（论坛偏爱站内图，不会被墙、不会因改仓库名失效），
就把 `images/` 里的图按序上传，然后把对应位置换成附件。

---

## 二、上传步骤

1. 登录 obsproject.com → **Resources** → **Add resource**
2. 分类选 **OBS Studio Resources → Scripts**（别选 Plugins，它不是编译插件，选错会被回帖纠正）
3. 标题、tag line、版本、标签照 `03-resource-meta-en.md` 抄
4. 资源文件二选一：
   - 传 `build/obs-mouse-fx-en-v1.1.1.zip`（30 KB，英文包，论坛托管，推荐）
     中文包同名同版本：`build/obs-mouse-fx-v1.1.1.zip`（36 KB），两者只差文件名里的 `-en`
   - 或填 GitHub Releases 外链（更新自动跟着走，但外链按钮不显眼，正文里也要放一次链接）
5. Description 粘贴 `01-resource-listing-en.bbcode.txt` 全文
6. 点 **Preview**，重点看三处：
   - 列表项有没有被拆散（BBCode 版刻意不用嵌套列表，XenForo 偶尔会把下一个 `[*]` 吃进子列表）
   - 九张图有没有全部显示（点开每张确认不是裂图）
   - 代码块里的 `trail → glow → ...` 那行有没有被吃格式
7. 提交。资源页会自动生成讨论帖

想要更多曝光：先在 **Scripts / Lua** 子版块用 `02-thread-post-en.md` 发一条普通帖，
再把资源页链接补在帖子末尾。新资源要过审核队列，普通帖直接进最新列表。

---

## 三、这个版本的取舍（为什么英文这么写）

- **Windows-only 放在最前面**，不塞进 Compatibility。OBS 论坛每条工具帖下面必然有 macOS
  用户问「能不能用」，先说清楚能省掉一半回帖。
- **不打「插件」旗号**。它是 Lua 脚本，走 Tools → Scripts，说成插件会招来「DLL 放哪」的追问。
- **主动写缺点**：`Caveats, up front` 那段是刻意的。技术社区对只讲优点的推广帖免疫，
  自己先说限制反而更容易被信。
- **层序图直接给**（`trail → glow → ripples → fill → ring → cursor`）。这是全篇唯一的
  技术卖点，用一行代码块说清楚，比形容词有效。
- **「不要两种用法同时开」单独成条**。这是最容易踩的坑，也是差评的主要来源，提前写死。
- 全文没有 emoji、没有 "game-changer"、没有 "revolutionary"。论坛读者对这类词的反应是关页面。

---

## 四、和现有材料的关系

- 事实、参数、排障表全部对齐 `README.en.md` 与 `build/release-notes-v1.1.0.md`；
  版本号统一 **1.1.1**，中英两个包同号（`obs-mouse-fx-v1.1.1.zip` /
  `obs-mouse-fx-en-v1.1.1.zip`），只靠文件名里的 `-en` 区分 —— 英文版不吃独立版本号。
  版本号不是手填的：`python dev-archive/build_en_lua.py` 从 `obs-fx/mouse-fx.lua` 读
  `SCRIPT_VERSION`，两边不一致直接报错退出，包名也按读到的数生成。
  已经办好了：1.1.1 已提交并打过 tag，release 上两个包都在同一版本下
  （`obs-mouse-fx-v1.1.1.zip` + `obs-mouse-fx-en-v1.1.1.zip`），
  论坛写的版本号和 GitHub 完全对得上，直接把 `obs-mouse-fx-en-v1.1.1.zip` 传上去即可。
- 成片 `promo-mg/out/promo.mp4`（73s）是中文口播版。要放进英文帖，先传 YouTube，
  再用 `[MEDIA=youtube]视频ID[/MEDIA]` 插在正文 `Features` 之后的位置；
  YouTube 简介用 `04-short-blurbs-en.md` 最后一节。
- 中文帖素材（`README.md`）没动，两边各自独立，改一边不会牵连另一边。

---

## 五、提交前最后一遍

```
□ 私人窗口登出状态点一次下载链接，确认 404 不是仓库可见性造成的
□ 正文里每张图都点开过
□ 版本号三处一致：标题区、正文下载段、zip 文件名
□ Windows-only 在第一屏可见
□ 资源分类是 Scripts
```
