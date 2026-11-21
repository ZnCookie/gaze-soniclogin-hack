# gaze-soniclogin-hack

> 让 [Gaze](https://gaze.gundulabs.com/) 在 SonicDE 的 `soniclogin` 登录管理器上也能自动解锁 KDE Wallet。

刷脸登录 SonicDE 后，KDE Wallet 仍然弹出密码框？这个仓库用约 50 行的 `LD_PRELOAD` shim 绕过 Gaze 的 PAM service 白名单，让钱包密码在刷脸时自动注入，无需重编译 Gaze、无需换掉 Sonic Login Manager、无需改任何 PAM 配置文件。

## 安装

### 1. 编译并安装 shim

```bash
git clone https://github.com/ZnCookie/gaze-soniclogin-hack.git
cd gaze-soniclogin-hack

# 若提示找不到 security/pam_appl.h，先装：sudo pacman -S pam
gcc -shared -fPIC -O2 -pthread \
    -o gaze_service_shim.so gaze_service_shim.c -ldl

sudo install -m 644 gaze_service_shim.so /usr/local/lib/gaze_service_shim.so
```

### 2. 替换 helper 为 wrapper

```bash
sudo cp -a /usr/lib/soniclogin-helper /usr/lib/soniclogin-helper.real

sudo tee /usr/lib/soniclogin-helper > /dev/null <<'EOF'
#!/bin/sh
LD_PRELOAD=/usr/local/lib/gaze_service_shim.so
export LD_PRELOAD
exec /usr/lib/soniclogin-helper.real "$@"
EOF
sudo chmod 755 /usr/lib/soniclogin-helper
```

### 3. 重启并验证

```bash
sudo systemctl restart soniclogin
```

完全注销，在登录界面密码框留空、刷脸登录，然后检查日志：

```bash
sudo journalctl -b --no-pager | grep -iE 'Face auth requested|kwallet' | tail -20
```

成功标志（两条同时满足）：

- `Face auth requested service="sddm" surface=Login`（不再是 `soniclogin`，说明 shim 生效）；
- **没有** `Couldn't get password (it is empty)`（说明钱包密码已成功注入）。

看到 `final socket path: .../kwallet5.socket` 即表示交接完成，钱包不再弹密码。

### 4. 安装升级 hook（可选但推荐）

`sonic-login-manager` 升级时会把 helper 还原成真二进制，解锁随之失效。安装 hook 后会自动重套 wrapper：

```bash
sudo bash gaze-hook.sh install
```

它会把脚本装到 `/usr/local/bin/gaze-hook.sh`、生成 `/etc/pacman.d/hooks/gaze-hook.hook`，并立即应用一次（当前已是 wrapper 会自动跳过，不改动现有状态）。

以后 `pacman -Syu` 升级 `sonic-login-manager` 时会看到：

```
Reapplying Gaze wrapper to soniclogin-helper...
[gaze-hook] 检测到升级后的真二进制，重套 wrapper
[gaze-hook] 完成（原件备份于 /usr/lib/soniclogin-helper.real）
```

## 卸载 / 回退

彻底恢复原状：

```bash
sudo rm -f /etc/pacman.d/hooks/gaze-hook.hook /usr/local/bin/gaze-hook.sh
sudo rm -f /usr/lib/soniclogin-helper
sudo mv /usr/lib/soniclogin-helper.real /usr/lib/soniclogin-helper
sudo systemctl restart soniclogin
```

## 问题背景

Gaze 的人脸识别本身工作正常，但它的 KWallet 自动解锁有个硬编码白名单——只有下面三个 PAM service 会触发钱包密码注入：

```rust
// Gaze v0.5.2: crates/pam-gaze/src/core/mod.rs
pub(crate) fn is_kwallet_login(service: Option<&str>) -> bool {
    matches!(service, Some("sddm" | "plasmalogin" | "plasmalogin-fingerprint"))
}
```

SonicDE 的 `soniclogin` 不在名单里，于是 Gaze 刷脸成功后**不会**把钱包密码写入 `PAM_AUTHTOK`，紧接着的 `pam_kwallet5.so` 拿到空密码：

```
pam_kwallet5(soniclogin:auth): Couldn't get password (it is empty)
pam_kwallet5(soniclogin:session): open_session called without kwallet5_key
```

结果就是每次登录都要手动输一次 kdewallet 密码。这是 Gaze 的设计边界，改配置、换 `kwallet` 包都无效。

## 原理

Gaze 判断白名单时，service 名来自标准调用 `pam_get_item(pamh, PAM_SERVICE, ...)`，其中 `PAM_SERVICE = 1`。我们在 `soniclogin-helper` 进程里用 `LD_PRELOAD` 拦截这个调用，**只把返回值 `"soniclogin"` 伪造成 `"sddm"`**，其余一切原样透传（尤其不碰 `PAM_AUTHTOK = 6`）。

这一处改动会同时修正整条链：

- `is_kwallet_login("sddm")` → true，命中白名单；
- `keyring_backend()` 返回 `Backend::KWallet`；
- `require_keyring` 变为 true，daemon 走 `verify_start_for_kwallet`；
- Gaze 把注册的钱包密码写入 `PAM_AUTHTOK`，`pam_kwallet5.so` 读到非空 token，钱包自动解锁。

关键点：PAM 栈读的仍是原来的 `/etc/pam.d/soniclogin`，已验证的刷脸流程完全不变；只是让 Gaze "看到"的名字落进了白名单。

由于 display manager 会在 exec helper 前清洗环境变量，`LD_PRELOAD` 不能只加在 `soniclogin.service` 上（实测无效），因此用一个 **wrapper 脚本**替换 `soniclogin-helper`，由 wrapper 自己设置 `LD_PRELOAD` 再 exec 真二进制。另一个脚本作为 **pacman hook**，在 `sonic-login-manager` 升级把 helper 还原成真二进制后自动重套 wrapper。

## 前置要求

| 项 | 说明 |
|---|---|
| Gaze | `gaze-bin` 0.5.2（白名单逻辑在 0.5.2 与 main 一致）；已完成刷脸注册与 `gaze keyring --kwallet` |
| SonicDE | 使用 Sonic Login Manager（`soniclogin.service`）作为显示管理器 |
| 编译工具 | `gcc`、`base-devel`；PAM 头文件由 `pam` 包提供（`security/pam_appl.h`） |
| helper 权限 | `/usr/lib/soniclogin-helper` **无 setuid 位、无 file capabilities**——否则 glibc 会忽略 `LD_PRELOAD` |

检查前置条件：

```bash
ls -l /usr/lib/soniclogin-helper     # 应为 -rwxr-xr-x，不是 rws
getcap /usr/lib/soniclogin-helper    # 应无输出
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `gaze_service_shim.c` | `LD_PRELOAD` 库源码：把 `PAM_SERVICE` 的 `soniclogin` 伪造成 `sddm` |
| `gaze-hook.sh` | 安装 pacman hook，并在升级后幂等地重套 wrapper（单文件，自安装） |
| `LICENSE` | MIT |

运行时涉及的系统路径：

| 路径 | 作用 | 能否删除 |
|---|---|---|
| `/usr/local/lib/gaze_service_shim.so` | shim 本体 | ❌ 不能 |
| `/usr/lib/soniclogin-helper.real` | 真 helper 备份 | ❌ 不能 |
| `/usr/lib/soniclogin-helper` | wrapper（由 hook 维护） | 可重建 |
| `/usr/local/bin/gaze-hook.sh` | hook 脚本 | 可重装 |
| `/etc/pacman.d/hooks/gaze-hook.hook` | hook 定义 | 可重装 |
