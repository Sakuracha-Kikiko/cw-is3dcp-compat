package dev.dsh.compat.cwissponder;

import io.redspace.ironsspellbooks.api.events.SpellPreCastEvent;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.world.effect.MobEffect;
import net.neoforged.bus.api.EventPriority;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import net.neoforged.neoforge.common.util.FakePlayer;
import net.neoforged.neoforge.event.tick.EntityTickEvent;

/**
 * 修掉「Create: Wizardry 的魔力枯竭效果误伤模拟施法者」这一个冲突。
 *
 * <p>问题链路（详见 iron_test_4/DIAGNOSIS-cw-vs-iss_ponder.md）：</p>
 * <ol>
 *   <li>ISS Ponder 在 <code>iss_ponder:spell_preview</code> 维度放一个 {@link FakePlayer} 真实施法，
 *       它的 Iron's {@code MagicData} 魔力初值为 0，30 tick 后才发起施法。</li>
 *   <li>Create: Wizardry 的 {@code CreateWizardry#onEntityTick(EntityTickEvent.Post)}（默认优先级）
 *       看到「Player 且魔力 &lt; 5」就给对方挂 60 tick 的 {@code create_wizardry:mana_depletion}。</li>
 *   <li>Create: Wizardry 的 {@code CreateWizardry#onSpellPreCast} 只要施法者身上有该效果就
 *       {@code SpellPreCastEvent#setCanceled(true)}，于是 Iron's 的
 *       {@code AbstractSpell#attemptInitiateCast} 返回 false。</li>
 *   <li>ISS Ponder 的 {@code beginCast} 把 false 一律映射成
 *       {@code gui.iss_ponder.cast_failed}（「法术未能取得有效目标」），预览从此不再播放。</li>
 * </ol>
 *
 * <p>本类用两个互相独立的钩子修正它，都只针对 {@link FakePlayer}，因此不会削弱任何真实玩家玩法：</p>
 * <ul>
 *   <li><b>正面修</b>：在同一个 {@link EntityTickEvent.Post} 上以 {@link EventPriority#LOWEST} 运行，
 *       必然晚于 Create: Wizardry 的默认优先级处理器，于是「挂效果」与「摘效果」发生在同一次事件派发里；
 *       同一 tick 稍后（{@code ServerTickEvent.Post}）才施法，枯竭已经不在身上，事件自然不会被打断。</li>
 *   <li><b>兜底</b>：万一效果来自别的路径，则在 {@link SpellPreCastEvent} 上同样以 LOWEST 运行，
 *       只对假玩家撤销「因枯竭而取消施法」的决定。</li>
 * </ul>
 *
 * <p>只按注册名查找枯竭效果，不引用 Create: Wizardry 的类，所以：没装 Create: Wizardry 时
 * 查找结果为空、本模组完全静默；Create: Wizardry 内部重构类名/方法名也不会让这里失效。</p>
 */
@EventBusSubscriber(modid = CwIssPonderCompat.MOD_ID)
public final class DepletionCompat {
    /** Create: Wizardry 的枯竭效果注册名（CWMobEffects.DEPLETION -> "mana_depletion"）。 */
    private static final ResourceLocation CW_DEPLETION =
            ResourceLocation.fromNamespaceAndPath("create_wizardry", "mana_depletion");

    private DepletionCompat() {
    }

    /**
     * 假玩家不是玩家：把别人刚给它挂上的枯竭效果立刻摘掉。
     *
     * <p>用 LOWEST 优先级保证与 Create: Wizardry 的挂载发生在同一次事件派发内、且在其之后。</p>
     */
    @SubscribeEvent(priority = EventPriority.LOWEST)
    public static void stripDepletionFromFakePlayers(EntityTickEvent.Post event) {
        if (event.getEntity() instanceof FakePlayer fakePlayer) {
            clearDepletion(fakePlayer);
        }
    }

    /**
     * 兜底：假装施法者（预览、机械施法、其他模组的模拟玩家）不应被「玩家魔力枯竭」的玩法拦住。
     */
    @SubscribeEvent(priority = EventPriority.LOWEST)
    public static void keepFakePlayerCastsAllowed(SpellPreCastEvent event) {
        if (event.getEntity() instanceof FakePlayer fakePlayer) {
            clearDepletion(fakePlayer);
            if (event.isCanceled()) {
                event.setCanceled(false);
            }
        }
    }

    private static void clearDepletion(FakePlayer fakePlayer) {
        Holder<MobEffect> depletion = BuiltInRegistries.MOB_EFFECT.getHolder(CW_DEPLETION).orElse(null);
        if (depletion != null && fakePlayer.hasEffect(depletion)) {
            fakePlayer.removeEffect(depletion);
        }
    }
}
