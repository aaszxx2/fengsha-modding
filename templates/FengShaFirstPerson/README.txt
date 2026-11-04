烽沙第一人称步行模组 v0.1.2

操作
- F8 或 Ctrl+Alt+F8：在领地中切换上帝视角与第一人称步行。
- F9 或 Ctrl+Alt+F9：紧急恢复原 Pawn 和建造视角。
- 备用触发：按 ~ 或 F10 打开游戏控制台，输入 fsfp 回车；输入 fsfp_return 回到原视角。
- WASD：移动；鼠标：转向；左 Shift：加速。

安装
- 需要烽沙专用 UE4SS + ContainerLoader v0.4。
- 将 FengShaFirstPerson 文件夹复制到 MOProject\Binaries\Win64\ue4ss\Mods\，并在 Mods\mods.txt 启用：FengShaFirstPerson : 1
- 修改后需要完全退出并重启游戏。

实现
- 运行时生成引擎 ACharacter，使用游戏已有的 SK_Soldier_MinFu_Garment_02 骨骼网格。
- 使用 CharacterMovement 的地面碰撞与重力；地形高度通过 MOProject 的 GetCurLandscapeHeightAtLocation 查询。
- 输入使用 PlayerController:IsInputKeyDown 与 GetInputMouseDelta，不依赖 FFI/user32。
- 尝试从运行时对象或已知资产路径解析士兵待机、走路动画；动画未解析时角色仍可移动，但可能保持站姿。
- 不修改存档、经济数据或 Mass 单位；退出时销毁临时角色并恢复原 Pawn 和 ViewTarget。

调试
- UE4SS 日志：MOProject\Binaries\Win64\ue4ss\UE4SS.log
- 日志中的“已加载”代表脚本启动；“已进入第一人称步行”代表切换逻辑启动。
- 视角异常时用 F9、Ctrl+Alt+F9 或控制台 fsfp_return 恢复；仍异常则重新载入存档。
- 尚未在游戏内验证本次新增的 F8/控制台备用入口。
