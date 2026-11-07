# Create: Wizardry × IronsSpellScrollPonder 冲突诊断

结论：**不是 Ponder 冲突，也不是渲染冲突，而是 Create: Wizardry 的「魔力枯竭（mana depletion）」功能把
IronsSpellScrollPonder 的模拟施法者（NeoForge FakePlayer）当成了「被抽干的玩家」，在它施法前取消了
`SpellPreCastEvent`，导致 `attemptInitiateCast` 返回 `false`，ISS Ponder 于是显示
`gui.iss_ponder.cast_failed` =「法术未能取得有效目标」。**

- 触发方（越界方）：Create: Wizardry `1.21.1-0.5.1-pre1`
- 受害方：IronsSpellScrollPonder `1.0.3`（`iss_ponder`）
- 上游基线：Iron's Spellbooks `1.21.1-3.16.x`、NeoForge `21.1.x`

---

## 1. 双方各自的实现

### 1.1 ISS Ponder：用 FakePlayer 在预览维度里真实施法

`IronsSpellScrollPonder-1.21.1/src/main/java/com/p1nero/iss_ponder/server/PreviewSessionManager.java`

| 位置 | 内容 |
| --- | --- |
| L107-108 | 预览维度 `iss_ponder:spell_preview` |
| L117-118 | `CAST_DELAY = 30`：会话建立后 **30 tick** 才发起施法 |
| L710-726 | `createSimulatedPlayer(...)`：`new FakePlayer(level, profile)` → `level.addFreshEntity(fake)`，不设置游戏模式、不初始化魔力 |
| L480-510 | `beginCast(...)`：`magicData.setMana(1_000_000)` → `spell.attemptInitiateCast(..., CastSource.COMMAND, ...)`；**`started == false` 就直接 `failPreview`** |
| L550-555 | `failPreview(...)` → 发送 `gui.iss_ponder.cast_failed` |
| L779-826 | 场景里生成 3 个僵尸靶子（这部分与本冲突无关） |

注意 L497-502：`attemptInitiateCast` 只要返回 `false`，就统一报「法术未能取得有效目标」。
这个文案**不代表真的找不到目标**，它是「施法被拒绝」的笼统兜底提示（这一点会误导排查方向）。

### 1.2 Create: Wizardry：低魔力施加「枯竭」，枯竭禁止施法

`Create-Wizardry-1.21.1/src/main/java/net/ttzplayz/create_wizardry/CreateWizardry.java`

```java
// L125：游戏事件总线注册（生效）
NeoForge.EVENT_BUS.register(this);

// L255-273：任何 Player（含 FakePlayer）魔力 < 5 → 挂 60 tick 的 DEPLETION，且每 tick 续期
@SubscribeEvent
public void onEntityTick(EntityTickEvent.Post event) {
    if (CWConfig.manaDepletionEnabled
            && event.getEntity() instanceof Player player && !player.level().isClientSide()
            && !player.isCreative() && !player.isSpectator()) {
        float mana = MagicData.getPlayerMagicData(player).getMana();
        if (mana < 5) {
            MobEffectInstance current = player.getEffect(CWMobEffects.DEPLETION);
            if (current == null || current.getDuration() < 30) {
                player.addEffect(new MobEffectInstance(CWMobEffects.DEPLETION, 60, 0, false, true, true));
            }
        }
    }
}

// L275-282：身上有 DEPLETION 就取消一切施法（不区分真假玩家、不复查当前魔力）
@SubscribeEvent
public void onSpellPreCast(SpellPreCastEvent event) {
    if (event.getEntity() != null && event.getEntity().hasEffect(CWMobEffects.DEPLETION)) {
        event.setCanceled(true);
    }
}
```

- `CWMobEffects.DEPLETION` = 注册名 `create_wizardry:mana_depletion`（`effect/CWMobEffects.java` L24-37）。
- 开关 `manaDepletionEnabled` 默认 **true**（`CWConfig.java` L154-157），以 `ModConfig.Type.COMMON` 注册（`CreateWizardry.java` L144）→ 文件 `config/create_wizardry-common.toml`。

---

## 2. 冲突链路（逐跳可查证）

1. **FakePlayer 的魔力从 0 开始。**
   Iron's 的 `MagicData` 是实体 attachment，默认构造 `mana = 0`
   （`MagicData.java` L54、`DataAttachmentRegistry.java` L26-27）；
   真实玩家的初始魔力只在登录/重生时写入
   （`ServerPlayerEvents.java` L411-412：`setMana(MAX_MANA * MANA_SPAWN_PERCENT)`）。
   ISS Ponder 只在**施法那一刻**才 `setMana(...)`，此前 30 tick 内 fake player 魔力 = 0。
   （`AttributeRegistry.java` L25-26：`MAX_MANA` 默认 100，`MANA_REGEN` 默认 1.0 → 每 10 tick 只回 1 点。）

2. **FakePlayer 每 tick 都会收到 `EntityTickEvent`。**
   NeoForge 1.21.1 把 `EntityTickEvent.Pre/Post` 打在 `ServerLevel#tickNonPassenger` 上
   （NeoForge PR #542 / #897），而 `ServerLevel#addPlayer/addEntity` 会把实体登记进
   `entityManager` 的 tick 列表，`ServerLevel#tick` 再经 `guardEntityTick(this::tickNonPassenger, ...)`
   逐个 tick。FakePlayer 的 `tick()` 虽然被 NeoForge 置空，但事件是在 `tick()` **外面**发的，
   所以照发不误 —— 这正是 ISS Ponder 必须手动调 `doTick()` 的原因
   （见 `TECHNICAL_NOTES.md` L76-78、`PreviewSessionManager.java` L539-548）。
   → 预览会话建立后的第 1 个 tick，Create: Wizardry 就看到 fake player 魔力 0。

3. **于是 fake player 被挂上 `mana_depletion`（60 tick，且持续续期）。**
   由于 30 tick 内魔力最多回到 3 点，整个等待期都满足 `mana < 5`。

4. **第 30 tick 施法被上游事件拦下。**
   Iron's `AbstractSpell#attemptInitiateCast`（`AbstractSpell.java` L281）：

   ```java
   if (!castResult.isSuccess()
           || !checkPreCastConditions(level, spellLevel, serverPlayer, playerMagicData)
           || NeoForge.EVENT_BUS.post(new SpellPreCastEvent(player, ...)).isCanceled()) {
       return false;
   }
   ```

   `beginCast` 虽然刚把魔力设为满值，但 **`DEPLETION` 效果还在身上（剩余几十 tick）**，
   Create: Wizardry 的 `onSpellPreCast` 依据「效果」而不是「当前魔力」判断 → 直接 `setCanceled(true)`
   → `attemptInitiateCast` 返回 `false`。

5. **ISS Ponder 报错。** `beginCast` L497-502 → `failPreview` L550-555 → 客户端显示
   「法术未能取得有效目标」，预览场景不再播放。

### 为什么是 100% 必现

- 每个会话/每次 replay/每次切法术都会 `createSimulatedPlayer` 新建 fake player → 魔力重新为 0。
- 枯竭效果一旦挂上持续 60 tick，而施法发生在第 30 tick，**时间窗必然重叠**。
- 两个模组单开都正常，是因为单开时没人给 fake player 挂效果、也没人取消 `SpellPreCastEvent`。

---

## 3. 一分钟验证（不用编译）

编辑 `config/create_wizardry-common.toml`：

```toml
[player_mana]
    # 关掉它，两个模组同时启用时 ISS Ponder 应立即恢复正常
    manaDepletionEnabled = false
```

若关掉后预览正常播放，则根因确认无误。
（反过来也可以验证：单开 ISS Ponder，用命令给预览里的假玩家任何来源的 `create_wizardry:mana_depletion`
效果，同样会看到「法术未能取得有效目标」。）

---

## 4. 建议修复

> 如果不想改动这两个模组：可以直接用现成的独立兼容模组
> [`本仓库`](../)（零 Mixin，只监听事件，约 70 行）；
> 也可以把 `manaDepletionEnabled` 关掉（零代码，但会牺牲真实玩家的枯竭玩法）。
> 数据包方案基本不可行，原因见该工程 README 的附录。

### 4.1 主责方：Create: Wizardry（最小改动）

假玩家不是玩家，不该参与「玩家魔力枯竭」这套玩法；`onSpellPreCast` 也应只针对真实玩家。

```java
import net.neoforged.neoforge.common.util.FakePlayer;   // 新增
import net.minecraft.server.level.ServerPlayer;          // 若尚未导入

// 1) 不要给假玩家挂枯竭
@SubscribeEvent
public void onEntityTick(EntityTickEvent.Post event) {
    ...
    if (CWConfig.manaDepletionEnabled
            && event.getEntity() instanceof ServerPlayer player
            && !(player instanceof FakePlayer)          // ← 关键
            && !player.level().isClientSide()
            && !player.isCreative() && !player.isSpectator()) {
        ...
    }
}

// 2) 不要拦截假玩家的施法（假玩家/机械施法都是模组内部模拟）
@SubscribeEvent
public void onSpellPreCast(SpellPreCastEvent event) {
    if (event.getEntity() instanceof ServerPlayer player
            && !(player instanceof FakePlayer)          // ← 关键
            && player.hasEffect(CWMobEffects.DEPLETION)) {
        event.setCanceled(true);
    }
}
```

更彻底一点（顺手修掉一个真实玩家侧的手感问题）：取消施法时复查**当前魔力**，
而不是依赖会滞留最多 60 tick 的效果：

```java
@SubscribeEvent
public void onSpellPreCast(SpellPreCastEvent event) {
    if (event.getEntity() instanceof ServerPlayer player
            && !(player instanceof FakePlayer)
            && MagicData.getPlayerMagicData(player).getMana() <= 0.0F) {
        event.setCanceled(true);
    }
}
```

### 4.2 防守方：IronsSpellScrollPonder（提高对其他模组的鲁棒性）

在 `PreviewSessionManager#createSimulatedPlayer` 里，**在 `level.addFreshEntity(fake)` 之前**
把假玩家初始化成「满魔力、无状态效果」，这样任何「低魔力/负面效果」类判定都不会误伤它：

```java
FakePlayer fake = new FakePlayer(level, profile);
initializeFakeConnection(fake);
fake.moveTo(...);
fake.setNoGravity(true);
fake.setInvulnerable(true);
fake.getAbilities().mayfly = true;
fake.getAbilities().flying = true;
// 新增：假玩家不是玩家，先补齐 Iron's 的魔力并清掉一切残留效果
MagicData.getPlayerMagicData(fake)
        .setMana((float) fake.getAttributeValue(AttributeRegistry.MAX_MANA));
fake.removeAllEffects();
level.addFreshEntity(fake);
```

另外建议（与本 bug 直接相关，属于可观测性）：`beginCast` 目前把 `attemptInitiateCast == false`
一律映射成「法术未能取得有效目标」，把真正原因吞掉了。可以改成
（a）记录 debug 日志，（b）把 `CastResult` 的动作栏文案/失败阶段透传给客户端状态栏，
这样下次别的模组再拦施法时，一眼就能看出是谁拦的。

---

## 5. 附：容易走偏的两个方向

- **不是** Create 的 Ponder 场景系统（`net.createmod.ponder`）被破坏：ISS Ponder 只是复用了 Ponder 的
  `PonderScene`/`PonderLevel` 做客户端呈现，报错发生在**服务端真实施法**阶段。
- **不是** mixin 冲突：两者没有注入同一个目标（Create: Wizardry 注入 `AbstractSpellCastingMob` 等，
  ISS Ponder 注入 `AbstractSpell` / `ServerLevel` / `PacketDistributor`），也没有 `@Overwrite` 互撞。
  Create: Wizardry 的 `AbstractSpellCastingMobMixin`（`SIPHON_LOCK` 时禁止生物施法）只作用于
  `AbstractSpellCastingMob`，与 FakePlayer 无关。
