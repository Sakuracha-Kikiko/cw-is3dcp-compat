package dev.dsh.compat.cwissponder;

import net.neoforged.fml.common.Mod;

/**
 * Create: Wizardry x Iron's Spell Scroll Ponder 兼容补丁。
 *
 * <p>只需要存在这个 mod 就会生效（逻辑在 {@link DepletionCompat}），
 * 不需要 Mixin，也不需要把 Create: Wizardry / ISS Ponder 当作编译依赖。</p>
 */
@Mod(CwIssPonderCompat.MOD_ID)
public final class CwIssPonderCompat {
    public static final String MOD_ID = "cw_issponder_compat";

    public CwIssPonderCompat() {
    }
}
