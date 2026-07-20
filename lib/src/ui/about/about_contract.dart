/// 保存“关于”页可持续渲染的状态。
final class AboutUiState {
  /// 创建不可变“关于”页状态。
  const AboutUiState({
    this.contentFilterUnlocked = false,
    this.blockAdultContent = true,
    this.adultKeywordCount = 0,
    this.updatingAdultKeywords = false,
  });

  /// 是否已经通过连点应用图标解锁“内容过滤管理”入口。
  final bool contentFilterUnlocked;

  /// 是否屏蔽成人内容；默认开启。
  final bool blockAdultContent;

  /// 当前生效关键词数量，供设置项副标题展示。
  final int adultKeywordCount;

  /// 是否正在从远程更新词库。
  final bool updatingAdultKeywords;

  /// 复制状态并只替换指定字段。
  AboutUiState copyWith({
    bool? contentFilterUnlocked,
    bool? blockAdultContent,
    int? adultKeywordCount,
    bool? updatingAdultKeywords,
  }) {
    return AboutUiState(
      contentFilterUnlocked: contentFilterUnlocked ?? this.contentFilterUnlocked,
      blockAdultContent: blockAdultContent ?? this.blockAdultContent,
      adultKeywordCount: adultKeywordCount ?? this.adultKeywordCount,
      updatingAdultKeywords: updatingAdultKeywords ?? this.updatingAdultKeywords,
    );
  }
}

/// 定义“关于”页允许发送的全部用户意图。
sealed class AboutIntent {
  /// 限制意图只能由本文件中的明确类型创建。
  const AboutIntent();
}

/// 请求读取当前屏蔽开关和词库数量。
final class LoadAboutStateIntent extends AboutIntent {
  /// 创建加载意图。
  const LoadAboutStateIntent();
}

/// 应用图标被点击一次；由 ViewModel 判定是否达到连点解锁条件。
final class TapAppIconIntent extends AboutIntent {
  /// 创建点击意图。
  const TapAppIconIntent();
}

/// 请求修改是否屏蔽成人内容。
final class ToggleBlockAdultContentIntent extends AboutIntent {
  /// 创建包含目标开关状态的切换意图。
  const ToggleBlockAdultContentIntent(this.enabled);

  /// 切换后的目标状态。
  final bool enabled;
}

/// 请求从远程更新成人内容词库。
final class UpdateAdultKeywordsIntent extends AboutIntent {
  /// 创建更新意图。
  const UpdateAdultKeywordsIntent();
}

/// 定义“关于”页交给路由层执行的一次性副作用。
sealed class AboutEffect {
  /// 限制副作用只能由本文件中的明确类型创建。
  const AboutEffect();
}

/// 请求显示短暂操作结果。
final class ShowAboutMessageEffect extends AboutEffect {
  /// 创建包含用户可读文本的消息副作用。
  const ShowAboutMessageEffect(this.message);

  /// 需要显示的消息。
  final String message;
}
