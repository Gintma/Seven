# OCR 与图片输入

## 从哪里改

[AppDelegate+MenusAndHotKeys](../../Sources/Seven/AppDelegate+MenusAndHotKeys.swift) 装配菜单行、目标动作与快捷键；[AppStatusMenu](../../Sources/Seven/AppStatusMenu.swift) 生成原生分组。[AppDelegate+ImageActions](../../Sources/Seven/AppDelegate+ImageActions.swift) 区分编辑与识别，[ImageImport](../../Sources/Seven/ImageImport.swift) 读取图片。[OCRCoordinator](../../Sources/Seven/OCRCoordinator.swift) 管理识别任务，[ScreenshotOCRWindowController](../../Sources/Seven/ScreenshotOCRWindowController.swift) 管理结果会话和原图。

## 必须保住什么

- 菜单栏按“翻译／截图／OCR”平铺。翻译依次为划词翻译、截图翻译、输入翻译、翻译并替换、历史记录；截图为截图、长截图、打开本地图片…、从剪贴板钉图；OCR 为 OCR、剪贴板 OCR、打开 OCR 窗口。设置与退出在末尾。动作与当前注册的快捷键对应。钉图输入类型见[截图与钉图](截图与钉图.md)。
- “打开本地图片…”进入编辑，Finder 打开图片进入 OCR；文件关联使用 Viewer/Alternate。只读本地原文件，一次处理一张。编辑和剪贴板 OCR 的图片入口只接受图像。打开图片不自动翻译或保存。
- 独立 OCR 在本机识别；静默 OCR 成功时只复制结果。新请求或取消使旧请求失效。新的普通结果替换旧会话并继承钉住状态；收起后从菜单重开会复用最近一次结果。替换或退出时释放旧原图并取消分析任务。
- [OCRImagePreview](../../Sources/Seven/OCRImagePreview.swift) 支持滚轮缩放、拖动平移、原图文字选择。右键或单击图片周围空白恢复适应并居中；拖动、图片内单击和选择文字都不能触发空白单击复原。正文编辑与原图选择分别维护。

## 怎样验证

[图片导入](../../Tests/SevenTests/ImageImportTests.swift) 覆盖剪贴板、本地格式、快捷键及空白单击；[OCR 协调器](../../Tests/SevenTests/OCRCoordinatorTests.swift) 覆盖取消与静默结果。[选区用途](../../Tests/SevenTests/OCRCapturePurposeTests.swift)、[原图文字选择](../../Tests/SevenTests/OCRImageSelectionTests.swift) 与[排版](../../Tests/SevenTests/OCRResultLayoutTests.swift) 分别验证框选、原图操作和正文。
