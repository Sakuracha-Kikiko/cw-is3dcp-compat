# cw_issponder_compat —— 不改动 Create: Wizardry / IronsSpellScrollPonder 的独立修复

针对的冲突：**Create: Wizardry + IronsSpellScrollPonder 同时启用时，法术思索（Ponder 预览）失效并显示
「法术未能取得有效目标」**。完整根因见 [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md)。

---

## 一、三条路线的可行性

| 方案 | 可行 | 代价 / 限制 |
| --- | --- | --- |
| **数据包** | ❌ 基本不可行 | 1.21.1 里 mob effect 是代码注册的，不是数据驱动；数据包也无法取消 NeoForge 事件、读写 Iron's 的 `MagicData`、或改 `create_wizardry-common.toml`。唯一的杠杆是 `#minecraft:tick` 函数每 tick 跑 `effect clear`，但它必须在「Create: Wizardry 挂效果」之后、「ISS Ponder 施法」之前执行——这依赖 `ServerFunctionManager#tick()` 与 `ServerTickEvent.Post` 的内部先后，属于时序赌博，且每秒跑 20 条命令，只压症状。**不推荐**。 |
| **改配置（零代码）** | ✅ | 把 `config/create_wizardry-common.toml` 里 `[player_mana] manaDepletionEnabled` 设为 `false`。代价：**真实玩家的魔力枯竭玩法被整体关掉**。适合只想赶紧能用的整合包。 |
| **独立模组（本工程）** | ✅ 推荐 | 约 70 行、**零 Mixin**、不依赖 Create: Wizardry 的类名/方法名；真实玩家的枯竭玩法保留。 |

## 二、这个模组怎么修的

问题链路（简述）：

```
ISS Ponder 造一个 FakePlayer（Iron's 魔力初值 0）
  → 第 1 tick：Create: Wizardry 看到 "Player 且魔力 < 5"，挂 60 tick 的 create_wizardry:mana_depletion
  → 第 30 tick：ISS Ponder 调 attemptInitiateCast
       → Iron's post(SpellPreCastEvent)
       → Create: Wizardry 看到身上有枯竭 → setCanceled(true)
       → attemptInitiateCast 返回 false
  → ISS Ponder failPreview → “法术未能取得有效目标”
```

`DepletionCompat` 用两个钩子处理，**都只针对 `FakePlayer`**：

1. **正面修**（主要机制）
   `@SubscribeEvent(priority = EventPriority.LOWEST) on EntityTickEvent.Post`
   → 假玩家每 tick 都会收到这个事件（NeoForge 在 `ServerLevel#tickNonPassenger` 里派发，假玩家的
   `tick()` 被置空也不影响事件照发）；我们的优先级低于 Create: Wizardry 的默认优先级，
   所以「它挂效果」和「我们摘效果」发生在**同一次事件派发**里。等同一 tick 稍后
   `ServerTickEvent.Post` 里 ISS Ponder 施法时，枯竭已经不在身上，`SpellPreCastEvent` 根本不会被取消。
   这一条不依赖 `SpellPreCastEvent` 的监听顺序，只依赖 `EntityTickEvent.Post` 的优先级（NORMAL < LOWEST，确定行为）。

2. **兜底**
   `@SubscribeEvent(priority = EventPriority.LOWEST) on SpellPreCastEvent`
   → 万一效果来自其它路径，就只对假玩家撤销「因枯竭而取消施法」的决定。

实现上的两个关键取舍：

- **不引用 Create: Wizardry 的类**，只用注册名 `create_wizardry:mana_depletion` 查效果。
  因此没装 Create: Wizardry 时它完全静默，Create: Wizardry 内部重命名类/方法也不会失效。
- **不用 Mixin**：NeoForge 事件总线按优先级排序、且 `ICancellableEvent` 允许把已取消的事件重新设为未取消，
  所以纯事件监听就够了（不需要注入别人的方法体，升级时也不会因为方法描述符变化而崩）。

## 三、构建（推荐：离线脚本，不需要 Gradle）

> **为什么不用 Gradle**：`maven.neoforged.net` 在国内被 DNS 污染 + 连接重置（试过 CDN77 的 4 个边缘 IP、
> 纯 HTTP、IPv6 全部失败；国内聚合镜像 Lss233's Mirror 虽然活着但 HTTPS 证书已过期，Gradle 无法使用）。
> 而本机已经装好了 Minecraft/NeoForge 运行库，所以直接用 `javac` 编译即可，完全离线。

### 用法

```powershell
cd cw-is3dcp-compat
.\build-offline.ps1                 # 构建 → build\libs\cw_issponder_compat-neoforge1.21.1-1.0.0.jar
.\build-offline.ps1 -Install        # 构建后自动复制进测试整合包 mods\
.\build-offline.ps1 -PackMods "D:\some\pack\mods"
```

脚本做的事：

1. 从 `gradle.properties` 读占位符值（唯一数据源）；
2. 自动定位依赖：`libraries\net\minecraft\client\1.21.1-*\client-*-srg.jar`（**Mojmap** 版，不是 `-extra`）、
   `net\neoforged\neoforge\21.1.*\*-universal.jar`、`fancymodloader\loader\4.*`、`bus\8.*`、
   以及 `com\mojang`（**DataFixerUpper 必须有**，因为 `Registry` 继承 `Keyable`）等支撑库；
3. Iron's 的 jar：优先 `libs\`，否则自动到 `.minecraft\versions\*\mods\` 里找 `*irons_spellbooks*.jar`；
4. `javac --release 21` 编译 → 展开 `neoforge.mods.toml` 占位符（**必须无 BOM**，FML 的 TOML 解析器不接受 BOM）
   → `jar` 打包。

两个已经踩过的坑（脚本里都处理了）：脚本本身保持**纯 ASCII**（Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 GBK 读，
中文注释会导致语法错误）；TOML 用 `[IO.File]::ReadAllText(..., UTF8Encoding($false))` 读取，
否则 PS 5.1 的 `Get-Content -Raw` 会把中文注释读成乱码、甚至吃掉换行导致依赖声明失效。

### 备用：Gradle 路径（需要能访问 maven.neoforged.net，例如挂全局代理）

工程本身仍是标准的 ModDevGradle 工程，网络通了以后 `.\gradlew.bat build` 即可，产物路径一致。
Gradle 也自带 Wrapper（8.11.1），命令与常见报错见下方表格。用代理时建议开**全局/TUN 模式**
（NeoFormRuntime 是独立 JVM，只配 `systemProp.https.proxyHost` 未必覆盖它）。

### Gradle 速查（备用路径）

### 前置

- **JDK 21**：本机已有（`C:\Program Files\Java\jdk-21.0.12.1`，`java`/`javac` 都在 PATH 上）。
- **网络**：能访问 `maven.neoforged.net`（否则见上方离线脚本）。
- **不需要**单独安装 Gradle：工程自带 Wrapper（`gradlew.bat`），它会自己下载并锁定 Gradle 8.11.1。

### 命令

```powershell
cd cw-is3dcp-compat
.\gradlew.bat build
# 产物：build\libs\cw_issponder_compat-neoforge1.21.1-1.0.0.jar
```

`gradlew.bat` 后面的第一个参数就是**任务名**，不写任务只会打印欢迎信息、什么也不编译。常用任务：

| 命令 | 作用 |
| --- | --- |
| `.\gradlew.bat tasks` | 列出所有可用任务 |
| `.\gradlew.bat compileJava` | 只编译（最快的语法检查） |
| `.\gradlew.bat build` | 编译 + 处理 `neoforge.mods.toml` + 打包 jar |
| `.\gradlew.bat clean build` | 清掉 `build\` 后完整重建 |
| `.\gradlew.bat build --stacktrace` | 出错时打印完整堆栈（排查必用） |
| `.\gradlew.bat build --offline` | 依赖已缓存后离线构建 |
| `.\gradlew.bat runClient` | 起 dev 客户端（见下方"冒烟测试"） |
| `.\gradlew.bat --stop` | 停掉后台 daemon 进程 |

### 第一次 `build` 会依次做什么

1. 下载 Gradle 8.11.1 发行包（约 130 MB，只下一次）；
2. 解析 `build.gradle` 里的 `net.neoforged.moddev` 插件 → 下载 NeoForge 21.1.219 + Minecraft 1.21.1 + Parchment 映射，并**反编译**出可编译的 Minecraft（这一步最慢，几分钟到十几分钟）；
3. 解析 Iron's 依赖（见下）→ 编译 `src/main/java`；
4. 把 `src/main/resources/META-INF/neoforge.mods.toml` 里的 `${...}` 占位符替换成 `gradle.properties` 的值，打进 `build\libs\*.jar`。

看到 `BUILD SUCCESSFUL` 且 `build\libs\` 里有 jar 就算成功。想确认占位符替换正确，可以直接读 jar 里的 toml：

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead("build\libs\cw_issponder_compat-neoforge1.21.1-1.0.0.jar")
$e = $z.Entries | Where-Object FullName -eq 'META-INF/neoforge.mods.toml'
(New-Object IO.StreamReader($e.Open())).ReadToEnd()
$z.Dispose()
```

### Iron's 依赖从哪来（最容易卡住的一步）

按以下优先级自动选择，不需要手动改代码：

1. **`libs\irons_spellbooks*.jar` 存在** → 直接用本地 jar 编译（完全离线）。
   把整合包 `mods\` 里的 `irons_spellbooks-1.21.1-3.16.3.jar` 复制进 `libs\` 即可
   （1.21.1 的模组 jar 本身就是 Mojmap，不需要 remap，可以直接当编译依赖）。
2. 否则 → 去 `https://api.modrinth.com/maven` 解析 `maven.modrinth:irons-spells-n-spellbooks:${irons_spellbooks_version}`。
   版本号在 `gradle.properties` 里，必须与整合包实际使用的一致。

构建时控制台会打印用的是哪一种，例如
`[cw_issponder_compat] 用本地 jar 编译: [irons_spellbooks-1.21.1-3.16.3.jar]`。

### 目录与缓存

| 位置 | 说明 |
| --- | --- |
| `build\` | 本工程的中间产物与最终 jar（可随时删） |
| `build\libs\` | **最终交付物**：`.jar` |
| `run\` | 只有跑 `runClient`/`runServer` 才出现，相当于 dev 版 `.minecraft`（含 `mods\`、`config\`、`logs\`） |
| `%USERPROFILE%\.gradle\caches` | 全局依赖缓存（约 1–2 GB，删了要重下） |
| `%USERPROFILE%\.gradle\wrapper\dists` | 下载过的 Gradle 发行包 |
| `%USERPROFILE%\.gradle\daemon\8.11.1\*.log` | 后台 daemon 日志（构建异常退出时看这里） |

### 常见报错

| 报错 | 处理 |
| --- | --- |
| `No matching toolchains found for types: 21` | 设 `JAVA_HOME`，或在 `%USERPROFILE%\.gradle\gradle.properties` 加 `org.gradle.java.installations.paths=C:\\Program Files\\Java\\jdk-21.0.12.1` |
| `Could not resolve maven.modrinth:...` | 用上面的 `libs\` 方案；或检查网络/代理 |
| 一直卡在 `Downloading ...` / 超时 | 网络问题，见下方代理配置 |
| 路径含中文/空格导致的怪异错误 | 把工程整体复制到纯 ASCII 路径（如 `C:\mcdev\compat-cw-issponder`）再构建 |

需要代理时，在 `%USERPROFILE%\.gradle\gradle.properties`（全局，不污染工程）里写：

```properties
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=7890
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=7890
```

### 冒烟测试（可选）

只想验证本模组能被正常加载、无副作用：把 `build.gradle` 里那行 `localRuntime "maven.modrinth:irons-spells-n-spellbooks:..."`
取消注释，再 `.\gradlew.bat runClient`。dev 环境里没有 Create/Create-Wizardry/ISS Ponder，
所以这里只能验证"不崩"，真正的功能验证要在整合包里做。

> ⚠️ 本工程由本次诊断会话生成，**没有在本机编译验证**（此环境没有 Gradle/NeoForge 缓存，shell 也无法访问外网）。
> 代码只用到 `FakePlayer`、`EntityTickEvent.Post`、`SpellPreCastEvent`、`BuiltInRegistries.MOB_EFFECT`
> 这几个稳定 API，但仍然建议先 `.\gradlew.bat build` 过一遍编译再进整合包。

## 四、验证步骤

1. 整合包 `mods/` 里同时放入：Create、Iron's Spellbooks、Create: Wizardry、IronsSpellScrollPonder、本补丁 jar。
2. **保持 `manaDepletionEnabled = true`**（这正是本补丁相对「关配置」的价值所在）。
3. 长按法术卷轴进入法术思索 → 预览应正常播放（不再出现「法术未能取得有效目标」）。
4. 反向回归：把魔力耗到 5 以下 → 枯竭效果照常出现、真实玩家照常无法施法（我们的钩子只对 `FakePlayer` 生效）。

## 附录：数据包方案（不推荐，仅供"完全无法加模组"时参考）

唯一可行的数据包写法是每 tick 用命令摘效果，**但它依赖 vanilla 的 tick 内部顺序，本会话无法实测**：

```
data/cwponderfix/function/tick.mcfunction
    execute in iss_ponder:spell_preview run effect clear @e[type=minecraft:player,name="Spell Preview"] create_wizardry:mana_depletion

data/minecraft/tags/function/tick.json
    { "values": ["cwponderfix:tick"] }

pack.mcmeta
    { "pack": { "pack_format": 48, "description": "cw/iss_ponder compat hack" } }
```

（1.21.1 的目录名是单数 `function` / `tags/function`，`pack_format` = 48。）

必须成立的前提，缺一不可：

1. `ServerFunctionManager#tick()`（即 `#minecraft:tick`）要排在实体 tick **之后**、
   `ServerTickEvent.Post`（ISS Ponder 在这里施法）**之前**——顺序一旦不满足，效果会在施法时仍在身上，方案失效；
2. 假玩家的名字必须仍是 `Spell Preview`（ISS Ponder 里硬编码，升级可能变）；
3. 效果 ID 仍是 `create_wizardry:mana_depletion`（没装 Create: Wizardry 时该命令会因未知效果直接报错）；
4. 只要有人在预览，就是每秒 20 条命令 + 20 次 `MobEffectEvent.Remove`。

所以它只能算"压症状的 hack"：**能加模组就用本工程**。

## 五、边界与后续

- 本补丁只解决「枯竭效果误伤模拟施法者」这一条冲突。Create: Wizardry 里其余机制
  （`SIPHON_LOCK` 只作用于 `AbstractSpellCastingMob`、Mana Siphon 只作用于半径内实体）经核查与预览无关。
- 如果 Create: Wizardry 以后把施法拦截从 `SpellPreCastEvent` 挪到别处，或换用另一个效果 ID，
  需要同步更新本补丁（改一行常量 / 补一个钩子）。
- 上游更正的推荐做法仍是在 Create: Wizardry 侧加 `!(player instanceof FakePlayer)` 判定，
  或在 `onSpellPreCast` 里复查当前魔力而不是依赖会滞留 60 tick 的效果；本模组只是把这件事放到第三方完成。
