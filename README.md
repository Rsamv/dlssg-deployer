# DLSSG 一键部署工具

面向 [DLSSG Native](https://github.com/sdli1995/dlssg_for_sm86) 的 Windows 一键部署 / 管理脚本，
让 **RTX 20 系（SM75）/ RTX 30 系（SM86）** 显卡也能在支持的游戏里启用 DLSS 帧生成。

- 上游项目地址：<https://github.com/sdli1995/dlssg_for_sm86>
- RTX 20 系 SM75 适配来源：<https://github.com/Coldwood1026/dlssg_for_sm75>

> 本工具只是把上游发布的代理 DLL 与 INI 复制到游戏目录，不修改、不重打包上游文件。

---

## 目录结构

```
DLSSG-Deployer/
├─ 一键安装DLSSG.cmd      # 双击运行入口
├─ Install-DLSSG.ps1      # 主脚本
├─ README.md              # 本说明
└─ mod/                   # 仅当自动下载时生成，存放 version.dll / INI / altnative
```

工具会自动在以下位置寻找 Mod 文件（`version.dll` + `dlssg_sm86.ini`）：

1. 本工具目录
2. 上一级目录
3. 上一级的 `dlssg_for_sm86-main/`
4. 本工具目录下的 `mod/`、`DLSSG/`

找不到时会询问是否从 GitHub 自动下载（也可用 `-ListOnly` 时自动下载）。

---

## 环境要求

- Windows 10 / 11 x64
- 支持 D3D12 且能开启 DLSS 帧生成的游戏
- NVIDIA 显卡：RTX 20 系（Turing，SM75）或 RTX 30 系（Ampere，SM86）
  - RTX 40/50 系原生支持帧生成，通常**无需**本 Mod
- NVIDIA 驱动（需提供 NGX / NVAPI / CUDA 接口），无需 CUDA Toolkit 或 Python

---

## 使用方法

双击 `一键安装DLSSG.cmd`，按提示操作：

1. **检测显卡与驱动**：自动识别架构并给出 `Router`（SM86 / SM75）与驱动版本。
2. **选择操作**：
   - `1` 安装 / 更新 Mod 到游戏
   - `2` 卸载 Mod
   - `3` 切换采样档位（精确 / 性能）
   - `q` 退出
3. **扫描游戏**：自动扫描 Steam / Epic / GOG / 常见目录中带 `nvngx_dlssg.dll` 的游戏；
   也可输入 `n` 手动添加路径。
4. **选择游戏**：输入编号（如 `1,3,5`）、`a` 全部、`q` 返回。
5. **选择档位**：
   - 精确档 `HardwareBilinear=0`（默认，输出最准确）
   - 性能档 `HardwareBilinear=1`（仅 SM86 生效，可能改变生成像素）
6. 安装完成后**重启游戏**，在画面设置中开启 DLSS 帧生成（2X / 3X / 4X）。

### 命令行参数

| 参数 | 说明 |
|---|---|
| `-ListOnly` | 只扫描并列出支持的游戏，不进入安装 |
| `-GamePath <路径...>` | 直接对指定目录安装，跳过扫描 |
| `-Preset Exact\|Performance` | 指定采样档位 |
| `-Uninstall` | 进入卸载流程 |
| `-SwitchPreset` | 进入档位切换流程 |
| `-RepoUrl <地址>` | 覆盖默认的 GitHub 项目地址 |
| `-NoPause` | 结束后不等待按键 |

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -GamePath "D:\SteamLibrary\steamapps\common\BlackMythWukong\b1\Binaries\Win64" -Preset Performance
powershell -ExecutionPolicy Bypass -File .\Install-DLSSG.ps1 -Uninstall
```

---

## 功能说明

- **显卡 / 驱动检测**：解析 NVIDIA 显卡型号、架构、驱动版本（如 `32.0.16.1062` → `610.62`）。
- **自动扫描游戏**：解析 Steam 库、Epic 清单、GOG 注册表及常见目录，定位渲染 EXE 所在目录。
- **安装 / 更新**：写入一个代理 DLL（默认 `version.dll`）与 `dlssg_sm86.ini`，并自动写入正确的 `Router`。
- **入口冲突处理**：若 `version.dll` 已被其他 Mod 占用，自动改用 `altnative` 中的替代入口。
- **卸载**：仅移除本项目的代理 DLL 与 INI，可一键从备份恢复；不会误删其他 Mod 的文件。
- **档位切换**：在精确档与性能档之间切换，无需重新安装。
- **自动下载**：缺少 Mod 文件时从 GitHub 拉取（优先整包 ZIP，失败则逐文件下载）。

---

## 安全说明

- 安装前会核验代理 DLL 的 Authenticode 签名者必须为 `DLSSG Native Project`，并在复制后比对 SHA256。
- 拒绝写入盘符根目录、`%windir%`、`Program Files`、`ProgramData` 等系统位置。
- 写入前检测目标文件是否为符号链接（重解析点），避免经链接覆盖任意文件。
- 安装 / 卸载前检测游戏是否在运行；覆盖前自动备份到 `dlssg_sm86_backup_<时间戳>`。
- 卸载采用「移动到 `dlssg_sm86_uninstalled_<时间戳>`」，可人工恢复。
- 脚本不联网（除非缺少文件且你同意下载）、不执行游戏目录中的任何内容。

**注意**：上游 DLL 使用**自签名证书**，Windows 默认不信任，SmartScreen 或杀毒软件仍可能告警，
这是上游项目的固有特性。请以官方发布来源与文件哈希为准。

---

## 卸载 / 回退

- 在菜单中选择 `2` 卸载；若有备份，可选择从最近备份恢复。
- 手动卸载：退出游戏后删除游戏目录中本工具添加的代理 DLL 与 `dlssg_sm86.ini`。
- 本工具产生的临时/备份目录：`dlssg_sm86_backup_*`、`dlssg_sm86_uninstalled_*`，可自行删除。

---

## 常见问题

**Q：扫描不到我的游戏？**
A：在列表界面输入 `n` 手动添加，路径指向渲染 EXE 所在目录（该目录应含 `nvngx_dlssg.dll`）。

**Q：安装后游戏里没有帧生成选项？**
A：确认游戏本身支持 DLSS 帧生成、显卡为 RTX 20/30 系、驱动较新，并已完全重启游戏。

**Q：提示 DLL 被其他 Mod 占用？**
A：工具会自动改用 `winmm.dll` / `dinput8.dll` / `winhttp.dll` / `dxgi.dll` 等替代入口。

**Q：自动下载失败、卡住或超时？**
A：下载设置了硬超时（默认 120 秒），连接失败或超时会**直接提示并退出**，不会一直等待。
   若网络受限，请先开启代理（科学上网 / Clash 等，确保系统代理或 TUN 模式已生效）后重试；
   脚本会自动读取系统代理。也可手动打开项目地址下载压缩包，解压后把
   `version.dll`、`dlssg_sm86.ini`、`altnative/` 放到本工具目录或 `mod/` 下。

**Q：如何更换下载源？**
A：使用 `-RepoUrl https://github.com/<用户>/<仓库>` 指定其他镜像或分支仓库。

---

## 免责声明

本工具仅用于本地便捷部署，Mod 版权与使用风险归上游项目所有。
使用前请阅读上游 `README` 与 `THIRD_PARTY_NOTICES.txt`，并自行承担相应风险。
