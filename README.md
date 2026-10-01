# DLSSG 一键部署工具

面向 [DLSSG for SM86 (Proxy)](https://github.com/sdli1995/dlssg_for_sm86) **0.3.5** 的 Windows 一键部署 / 管理脚本，
让 **RTX 20 系（SM75）/ RTX 30 系（SM86）** 显卡也能在支持的游戏里启用 DLSS 帧生成。

- 上游项目地址：<https://github.com/sdli1995/dlssg_for_sm86>
- RTX 20 系 SM75 内核族来源：<https://github.com/Coldwood1026/dlssg_for_sm75>

> 本工具只是把上游发布的代理 DLL 与 INI 复制到游戏目录，不修改、不重打包上游文件。
> 0.3.5 已由 native 模式回退到代理模式，出厂 INI 会自动按物理显卡选择 SM75 / SM86，**无需手填 `Router`**。

---

## 目录结构

```
DLSSG-Deployer/
├─ 一键安装DLSSG.cmd      # 双击运行入口
├─ Install-DLSSG.ps1      # 主脚本
├─ README.md              # 本说明
└─ mod/                   # 仅在“附近找不到 Mod 包”时由自动下载生成
```

工具按以下顺序寻找 Mod 包，只要目录里有 `version.dll` / `dlssg_sm86.ini` / `alternatives\`（含 DLL）即视为有效包：

1. 本工具目录
2. 上一级目录（例如把本工具放在 `dlssg_for_sm86-main\DLSSG-Deployer\` 时）
3. 上一级的 `dlssg_for_sm86-main\`、`dlssg_sm86-main\`、`dlssg_for_sm75-main\`
4. 本工具目录下的 `mod\`、`DLSSG\`

### 上游 0.3.5 包结构（供对照）

```
dlssg_for_sm86-main/
├─ version.dll           # 主代理入口（310.9 运行库，支持 6X）
├─ dlssg_sm86.ini        # 出厂配置
├─ alternatives/         # 备用代理入口：winmm / dbghelp / dinput8 / dxgi / d3d12
├─ 310.1/                # 老版运行库（version.dll + alternatives/），可选
├─ docs/                 # INSTALL.md 等完整文档
└─ archive/              # 历史版本
```

---

## 环境要求

- Windows 10 / 11 x64，游戏为 D3D12
- NVIDIA 显卡：RTX 20 系（Turing，SM75）或 RTX 30 系（Ampere，SM86）
  - RTX 40/50 系原生支持帧生成，通常**无需**本 Mod
- NVIDIA 驱动（需提供 NGX / NVAPI / CUDA 接口）；上游实测 591.86 与 610.74 可用
  - cubin 需约 R580+，更旧驱动自动回退 PTX（仅首帧多一次 JIT）
- 无需 CUDA Toolkit，无需 Python

---

## 使用方法

双击 `一键安装DLSSG.cmd`，按提示操作：

1. **检测显卡与驱动**：识别架构（SM75 / SM86）与驱动版本（如 `32.0.16.1062` → `610.62`）。
2. **选择操作**：
   - `1` 安装 / 更新 Mod 到游戏
   - `2` 卸载 Mod
   - `3` 切换一致性档位（`Optimized` 0–3）
   - `q` 退出
3. **扫描游戏**：自动扫描 Steam / Epic / GOG / 各盘符常见目录（含盘符根目录）中带
   `nvngx_dlssg.dll` 的游戏；列表为空时才提示手动输入路径。
4. **选择游戏**：输入编号（如 `1,3,5`）、`a` 全部、`n` 手动输入路径、`q` 返回。
5. **选择档位** `[FrameGeneration] Optimized`：

   | 档位 | 含义 | 画面 |
   |---|---|---|
   | `0` | 原厂内核，不加速 | 与官方逐位一致（最保守） |
   | `1` | 逐位一致的加速（**默认，推荐**） | 与官方逐位一致 |
   | `2` | 档位 1 + 有损图像内核（仅 310.9 构建） | PSNR 约 50 dB 以上 |
   | `3` | 全部有损加速 | 画质代价最大，最快 |

6. 安装完成后**重启游戏**，在图形设置中开启 DLSS 帧生成并选 2X / 3X / 4X
   （310.9 构建且游戏自带新插件时可至 6X）。

### 命令行参数

| 参数 | 说明 |
|---|---|
| `-ListOnly` | 只扫描并列出支持的游戏，不进入安装 |
| `-GamePath <路径...>` | 直接对指定目录安装，跳过扫描 |
| `-Tier <0-3>` | 指定一致性档位（见上表） |
| `-Uninstall` | 进入卸载流程 |
| `-SwitchPreset` | 进入档位切换流程 |
| `-RepoUrl <地址>` | 覆盖默认的 GitHub 项目地址 |
| `-NoPause` | 结束后不等待按键 |

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -GamePath "D:\SteamLibrary\steamapps\common\BlackMythWukong\b1\Binaries\Win64" -Tier 1
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -SwitchPreset -Tier 0
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -Uninstall
```

---

## 功能说明

- **显卡 / 驱动检测**：解析 NVIDIA 显卡型号、架构、驱动版本。
- **自动扫描游戏**：解析 Steam 库、Epic 清单、GOG 注册表、各盘符常见目录与盘符根目录，
  定位渲染 EXE 所在目录（搜索深度 8）。
- **安装 / 更新**：写入一个代理 DLL 与 `dlssg_sm86.ini`，并写入所选一致性档位。
  默认代理入口为根目录 `version.dll`。
- **入口冲突处理**：若 `version.dll` 已被其他 Mod 占用，自动按
  `winmm.dll` → `dbghelp.dll` → `dinput8.dll` → `dxgi.dll` → `d3d12.dll` 顺序改用未被占用的入口。
- **旧版本就地升级**：若目标目录里是本项目**旧版本**的代理 DLL（例如 0.2.4 的 `version.dll`），
  会直接在原位置升级为新版，而不是另加一个入口；同目录下其它本项目的代理入口
  （如上一轮留下的 `winmm.dll`）会被移入备份目录——两个不同版本同时注入同一进程会互相冲突。
  判定依据是 SHA256 是否命中包内已知文件（含 `archive\` 历史版本），**其他 Mod 的文件一律不动**。
- **卸载**：按 SHA256 精确识别本项目文件，仅移除本项目的代理 DLL 与 INI，可一键从备份恢复。
- **档位切换**：改写 `[FrameGeneration] Optimized`，无需重新安装。
- **缺失文件补齐**：包内缺少根目录 `version.dll` / `dlssg_sm86.ini` 时，可在提示后从 GitHub 补齐；
  附近完全没有 Mod 包时，可整包下载到 `mod\`。

### 可选进阶配置

工具的档位切换只改写 `Optimized`。以下键可自行编辑游戏目录里的 `dlssg_sm86.ini`（改完重启游戏）：

- `MaxGeneratedFrames`：`3` = 最多 4X（出厂），`5` = 最多 6X（仅 310.9 构建，且游戏需自带较新插件）。
- `Preset`（`[Compatibility]`）：DLSSG 渲染预设（UI 重组），`Auto` / `A` / `B`，仅 310.9。
- `Router` / `KernelImage` / `SM75Family` 等：出厂默认 `Auto` 已按物理显卡自动选择，通常无需填写。
  完整键表见上游 `docs/INSTALL.md`。

---

## 安全说明

- 安装前核验代理 DLL 的 Authenticode 签名者必须为 `DLSSG for SM86`（旧版为 `DLSSG Native Project`），
  并在复制后比对 SHA256。
- 拒绝写入盘符根目录、`%windir%`、`Program Files`、`ProgramData` 等系统位置。
- 写入前检测目标文件是否为符号链接（重解析点），避免经链接覆盖任意文件。
- 安装 / 卸载前检测游戏是否在运行；覆盖前自动备份到 `dlssg_sm86_backup_<时间戳>`。
- 卸载采用「移动到 `dlssg_sm86_uninstalled_<时间戳>`」，可人工恢复；**不会误删其他 Mod 的同名文件**。
- 脚本不主动联网（仅在缺少文件且你同意时下载），不执行游戏目录中的任何内容。

**注意**：上游 DLL 使用自签名证书 `CN=DLSSG for SM86 (self-signed)`，
Windows 默认不信任，SmartScreen 或杀毒软件仍可能告警——这是上游项目的固有特性，
与杀软报毒是两回事。请以官方发布来源与文件哈希为准。

---

## 卸载 / 回退

- 在菜单中选择 `2` 卸载；若有备份，可选择从最近备份恢复。
- 手动卸载：退出游戏后删除游戏目录中本工具添加的代理 DLL 与 `dlssg_sm86.ini`。
- 本工具产生的临时/备份目录：`dlssg_sm86_backup_*`、`dlssg_sm86_uninstalled_*`，可自行删除。

---

## 常见问题

**Q：扫描不到我的游戏？**
A：列表为空时会提示手动输入，路径指向渲染 EXE 所在目录（该目录应含 `nvngx_dlssg.dll`）。

**Q：安装后游戏里没有帧生成选项？**
A：确认游戏本身支持 DLSS 帧生成、显卡为 RTX 20/30 系、驱动较新，并已完全重启游戏。
   仍不行时把 `[Logging] Level` 改为 `2`，查看游戏目录 `dlssg_sm86\logs\backend_*.jsonl` 是否出现
   `route active=true`。

**Q：提示 DLL 被其他 Mod 占用？**
A：工具会自动改用 `winmm.dll` / `dbghelp.dll` / `dinput8.dll` / `dxgi.dll` / `d3d12.dll` 中的可用入口。
   注意 `dxgi.dll` / `d3d12.dll` 位于 D3D12 渲染热路径上，是上游标注的“风险更高”的入口，仅在前几个不可用时才会用到。

**Q：能开 6X 吗？**
A：需要 310.9 构建（根目录 `version.dll`）且游戏自带较新的 Streamline 帧生成插件。
   把 `MaxGeneratedFrames` 改成 `5`；自带旧版 4X 插件的游戏无论写几都只有 4X。

**Q：自动下载失败、卡住或超时？**
A：下载设置了硬超时（默认 120 秒），连接失败或超时会**直接提示并退出**，不会一直等待。
   若网络受限，请先开启代理（科学上网 / Clash 等，确保系统代理或 TUN 生效）后重试；脚本会自动读取系统代理。
   也可手动打开项目地址下载压缩包，解压后把 `version.dll`、`dlssg_sm86.ini`、`alternatives\`
   放到本工具目录或 `mod\` 下。

**Q：如何更换下载源？**
A：使用 `-RepoUrl https://github.com/<用户>/<仓库>` 指定其他镜像或分支仓库。

---

## 免责声明

本工具仅用于本地便捷部署，Mod 版权与使用风险归上游项目所有。
使用前请阅读上游 `README`、`docs/INSTALL.md` 与 `THIRD_PARTY_NOTICES.txt`，并自行承担相应风险。
