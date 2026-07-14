/// 表示可持久化书源，对应 Android `data.entities.BookSource`。
///
/// M2 将各规则对象保存为原始 JSON 文本，M3 再转换为强类型规则；这样数据库对象不会
/// 接收未经验证的动态 Map，同时保留历史导入字段。
final class BookSource {
  /// 创建不可变书源。
  const BookSource({
    required this.bookSourceUrl,
    required this.bookSourceName,
    this.bookSourceGroup,
    this.bookSourceType = 0,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleExplore,
    this.searchUrl,
    this.ruleSearch,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.ruleReview,
    this.eventListener = false,
    this.customButton = false,
    this.homepageModules,
    this.extraFieldsJson,
  });

  /// 含协议的书源地址，也是 `book_sources` 表主键；不进行 URL 规范化。
  final String bookSourceUrl;
  /// 书源显示名称。
  final String bookSourceName;
  /// 逗号等分隔符组织的书源分组文本。
  final String? bookSourceGroup;
  /// Android `BookSourceType` 数值：0 文本、1 音频、2 图片、3 文件、4 视频。
  final int bookSourceType;
  /// 用于匹配详情页 URL 的正则文本。
  final String? bookUrlPattern;
  /// 用户手动排序值。
  final int customOrder;
  /// 是否参与搜索等常规操作。
  final bool enabled;
  /// 是否参与发现页操作。
  final bool enabledExplore;
  /// 书源 JavaScript 公共库代码。
  final String? jsLib;
  /// 是否启用自动 Cookie Jar；`null` 保留历史 JSON 中未声明该字段的语义。
  final bool? enabledCookieJar;
  /// 并发率规则原始文本。
  final String? concurrentRate;
  /// 请求头 JSON 或规则文本。
  final String? header;
  /// 登录页面地址或规则。
  final String? loginUrl;
  /// 登录 UI 定义文本。
  final String? loginUi;
  /// 登录状态检查 JavaScript。
  final String? loginCheckJs;
  /// 封面解密 JavaScript。
  final String? coverDecodeJs;
  /// 书源注释。
  final String? bookSourceComment;
  /// 自定义变量说明。
  final String? variableComment;
  /// 最后更新时间，Unix Epoch 毫秒；0 表示未知。
  final int lastUpdateTime;
  /// 最近响应耗时，单位毫秒；Android 默认 180000。
  final int respondTime;
  /// 智能排序权重。
  final int weight;
  /// 发现入口 URL 或规则文本。
  final String? exploreUrl;
  /// 发现筛选规则原始文本。
  final String? exploreScreen;
  /// 发现规则对象的 JSON 文本。
  final String? ruleExplore;
  /// 搜索 URL 或规则文本。
  final String? searchUrl;
  /// 搜索规则对象的 JSON 文本。
  final String? ruleSearch;
  /// 详情规则对象的 JSON 文本。
  final String? ruleBookInfo;
  /// 目录规则对象的 JSON 文本。
  final String? ruleToc;
  /// 正文规则对象的 JSON 文本。
  final String? ruleContent;
  /// 段评规则对象的 JSON 文本。
  final String? ruleReview;
  /// 是否执行书源事件回调规则。
  final bool eventListener;
  /// 是否显示书源控制的自定义按钮。
  final bool customButton;
  /// 首页模块定义的 JSON 数组文本。
  final String? homepageModules;

  /// 导入时未被当前模型识别的字段 JSON；重新保存时必须原样保留。
  final String? extraFieldsJson;

  /// 复制管理页面允许直接修改的字段，其余规则和未知字段保持不变。
  BookSource copyWithManagement({
    bool? enabled,
    bool? enabledExplore,
    String? bookSourceGroup,
    int? customOrder,
  }) {
    return BookSource(
      bookSourceUrl: bookSourceUrl,
      bookSourceName: bookSourceName,
      bookSourceGroup: bookSourceGroup ?? this.bookSourceGroup,
      bookSourceType: bookSourceType,
      bookUrlPattern: bookUrlPattern,
      customOrder: customOrder ?? this.customOrder,
      enabled: enabled ?? this.enabled,
      enabledExplore: enabledExplore ?? this.enabledExplore,
      jsLib: jsLib,
      enabledCookieJar: enabledCookieJar,
      concurrentRate: concurrentRate,
      header: header,
      loginUrl: loginUrl,
      loginUi: loginUi,
      loginCheckJs: loginCheckJs,
      coverDecodeJs: coverDecodeJs,
      bookSourceComment: bookSourceComment,
      variableComment: variableComment,
      lastUpdateTime: lastUpdateTime,
      respondTime: respondTime,
      weight: weight,
      exploreUrl: exploreUrl,
      exploreScreen: exploreScreen,
      ruleExplore: ruleExplore,
      searchUrl: searchUrl,
      ruleSearch: ruleSearch,
      ruleBookInfo: ruleBookInfo,
      ruleToc: ruleToc,
      ruleContent: ruleContent,
      ruleReview: ruleReview,
      eventListener: eventListener,
      customButton: customButton,
      homepageModules: homepageModules,
      extraFieldsJson: extraFieldsJson,
    );
  }
}
