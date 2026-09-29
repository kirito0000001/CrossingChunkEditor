# CrossingChunkEditor

> UE 编辑器插件：在内容浏览器里右键标记 Chunk，在一页里维护分块规则、检查打包内容、跑打包并看实时日志。

给 UE 5.8「按目录分 Chunk」那套流程做的编辑器前端。

## 背景

UE 5.8 里 `UPrimaryAssetLabel`（AST_* 标签）在 cook 阶段**不生效**：

- 规则注册代码写在 `UPrimaryAssetLabel::UpdateAssetBundleData()` 末尾，位于 `#if WITH_EDITORONLY_DATA` 内；
- 5.8 的 `UPrimaryAssetLabel` 没有 `PostLoad` 覆写，而 `UAssetManager::ApplyPrimaryAssetLabels()` 正是指望 `PostLoad` 去注册规则。

结果是**内存里的 chunk 分配完全正确，落到磁盘上永远只有 `pakchunk0/2/3`**。

真正能按目录改写 chunk 归属的是引擎自带的 `DefaultPakFileRules.ini` —— pak 阶段的 `ApplyPakFileRules()` 逐文件改写归属（规则**按书写顺序匹配，首个命中生效**，所以深目录必须写在浅目录前面）。

这套链路的完整排查过程见知乎：[《UE5 按目录分 Chunk 记录》](https://zhuanlan.zhihu.com/p/2084724901970289419)。本插件就是那篇文章里那套流程的编辑器侧封装。

## 功能

### 1. 内容浏览器右键标记

在内容浏览器里右键**一个文件夹** → 「Chunk 分块」：

- **状态行**先告诉你这个目录现在算哪个 chunk：
  - `当前：Chunk 7 · 角色-桐人（本目录直接标记）`
  - `当前：Chunk 7 · 角色-桐人（继承自 /Game/GameActor2D）`
  - `当前：未分类 —— 本次新增，会进新建的 Chunk 9`
- **指定为 Chunk**：选一个已有分块（单选，带名字和目录数），或者用目录名新建一个
- **取消本目录的标记**：取消后重新跟随最近的上级标记

### 2. 《二游打包》页

入口：编辑器主菜单 **平台 → 二游打包**。

| 区块 | 内容 |
| --- | --- |
| 分块规则 | 号、名字（双击改）、目录数、文件数、体积、本次变化（`+新增 -删除 ~修改`）、解散 |
| 本次新增（未分类目录） | 上次打包里没归类的目录；每行可「指派到」某个分块，或「定位」到内容浏览器 |
| 打包 | 目标（Windows / 安卓 / 服务器）× 模式（常规补丁 / 版本更新 / 快速验证）；**再点一次 = 停止** |
| 地图 | 扫 AssetRegistry 列出所有 World，勾选本次 cook 哪些图（客户端 / 服务器分开记） |
| 版本 | 玩家版本（打包时写进安卓 `VersionDisplayName`）；基线版本由玩家版本的主版本段自动派生（`1.4.2 → 1.4`） |
| 状态 | 报告 / 产物 / 基线 / 当前平台设置（包名、SDK、图标是不是还是引擎默认……） |
| 运行设置 | Cook 进程数（1–4）、基线位置 |
| 实时日志 | 按行着色（红=错误 黄=警告 绿=成功 青=平台设置）；打包结束弹原生 toast + 播编辑器自带的编译提示音 |

工具条上还有：复制命令、撤销解散、日志目录、清除缓存。

## 安装

把 `CrossingChunkEditor` 整个目录放到 `<项目>/Plugins/` 下，重新生成项目文件并编译。

模块类型 `Editor`，`LoadingPhase = PostEngineInit`。

## 前置：三份项目侧脚本

插件负责「规则维护 + 打包入口」，真正干活的是项目里的三份 PowerShell 脚本，**它们不在本仓库**：

| 脚本 | 职责 |
| --- | --- |
| `Tools/Pack-CrossingVoid.ps1` | 打包 / 清缓存 / 状态查询 —— 页面上每个按钮最终都是调它 |
| `Tools/Build-PakFileRules.ps1` | 把规则 ini 翻译成 `Config/DefaultPakFileRules.ini` |
| `Tools/Build-ChunkReport.ps1` | 打包后产分包报告（页面读它算文件数 / 体积 / 变化） |

页面调脚本时传的参数：`-Mode -Platform -Target -ArchiveDir -ReleaseRoot -Maps -ReleaseVersion -PlayerVersion -CookProcessCount`；另有 `-ClearCache` 与 `-Status` 两个独立入口。

**本插件是为 CrossingVoid 这个项目写的**，换项目要把这套脚本接口对上。

## 规则文件

`<项目>/Config/DefaultCrossingChunk.ini`：

```ini
[/Script/CrossingChunk.CrossingChunkRuleSet]
; 基础包：开机就要用的
+Chunks=(ChunkName="基础包",ChunkId=0,Folders=((Path="/Game/UI"),(Path="/Game/BaseArt")),Priority=0,bIncludeInInstallPackage=True,ForceExcludeFolders=,Comment="")
; 角色单独成包
+Chunks=(ChunkName="角色-桐人",ChunkId=7,Folders=((Path="/Game/GameActor2D/SAO_Kirito")),Priority=0,bIncludeInInstallPackage=False,ForceExcludeFolders=,Comment="")
```

编辑器里改的就是这一份 —— **右键菜单、页面、打包脚本读的是同一个文件**，不存在两边不同步。

### 目录继承

一个目录没有自己的标记时，往上找最近的已声明目录。所以标了 `/Game/GameActor2D`，它下面的子目录都跟着走；想让某个子目录单独成包，再单独标它即可（子目录优先）。

### 未分类

哪一层都没标过的目录 = 这批东西是这次新增的。打包时会被收进一个**新 chunk**（号 = 现有最大号 + 1），基础包不动，玩家只需要下一个新包。

## 用起来是什么样

1. 加了资源 → 在内容浏览器右键它所在的目录 → 「指定为 Chunk」；或者什么都不做，让它进新 chunk
2. 打开《二游打包》页 → 确认「本次新增」清单和预期一致
3. 选目标、选模式、勾地图 → 开始打包
4. 打完看报告：每个 chunk 多少文件、多大体积、比上次变了多少

这一页的定位是**打包前的检查台**，不是打包按钮页 —— 「我这次只动了 3 个角色图，面板却说 chunk3 新增了 500 个文件」，那说明有东西误入或误删了。

## 几个设计取舍

- **不在编辑器里估算体积**：估不准会误导，体积一律以打包报告为准。
- **页面不自己重算规则匹配**：两份实现必然漂移，一律读脚本产出的报告。
- **chunk 号不提供随意修改**：号是下载器认的稳定标识，改了会让已发布的包对不上；改名不受影响（名字只用于显示）。
- **不改引擎**：全部走 `DefaultPakFileRules.ini` 这套官方配置。

## 已知状态

- 打包链路完整验证过的是 **Windows + Client**。安卓与专用服务器脚本层面支持，验证还在推进（安卓产物是 APK + OBB，没有 `Content/Paks` 目录，收尾的体积统计和清单归档目前会被跳过）。
- 「解散分块」的撤销只在**当前编辑器会话**内有效。
- 「本次新增」清单来自上一次打包报告；刚打开、还没打过包时它是空的。

## 参考

- [UE5 按目录分 Chunk 记录](https://zhuanlan.zhihu.com/p/2084724901970289419) —— 链路排查与最终方案的完整记录
- [UE5 非 uasset 资产 Chunk/Pak 划分踩坑笔记](https://zhuanlan.zhihu.com/p/689375430) —— `DefaultPakFileRules.ini` 这条线的起点
