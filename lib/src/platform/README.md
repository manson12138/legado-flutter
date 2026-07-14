# platform

平台能力抽象目录。领域与 UI 只能依赖这里定义的稳定抽象，Android/iOS 实现由组合根选择；M1 不创建未来能力空壳。

后续接口使用能力名称，例如 `FilePickerGateway`；平台实现使用明确后缀，例如 `AndroidFilePickerGateway`、`IosFilePickerGateway`。MethodChannel 名称、方法名、参数 DTO 和错误码必须集中定义，失败需转换为受控 `AppError`，不能把动态 Map 直接传给 UI。
