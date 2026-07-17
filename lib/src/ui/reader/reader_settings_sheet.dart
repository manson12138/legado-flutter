import 'package:flutter/material.dart';

import '../../domain/model/reader_content.dart';
import '../theme/app_tokens.dart';

/// 对齐 Android ReadStyle/TextTitle/Padding/System 菜单的 P1 阅读显示设置面板。
final class ReaderSettingsSheetBody extends StatefulWidget {
  /// 创建显示设置面板。
  const ReaderSettingsSheetBody({
    required this.initialConfig,
    required this.onApply,
    super.key,
  });

  /// 打开面板时的配置快照。
  final ReaderDisplayConfig initialConfig;

  /// 点击应用时提交完整配置。
  final ValueChanged<ReaderDisplayConfig> onApply;

  /// 创建设置面板状态。
  @override
  State<ReaderSettingsSheetBody> createState() => _ReaderSettingsSheetBodyState();
}

/// 持有尚未应用的阅读设置草稿。
final class _ReaderSettingsSheetBodyState extends State<ReaderSettingsSheetBody> {
  /// 当前草稿配置。
  late ReaderDisplayConfig _draft;

  /// 初始化草稿配置。
  @override
  void initState() {
    super.initState();
    _draft = widget.initialConfig;
  }

  /// 构建分层设置面板，避免所有高频设置堆在一个长列表里。
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.medium,
                SpacingToken.medium,
                SpacingToken.medium,
                0,
              ),
              child: Text('显示设置', style: Theme.of(context).textTheme.titleLarge),
            ),
            const TabBar(
              tabs: <Widget>[
                Tab(text: '样式'),
                Tab(text: '文字'),
                Tab(text: '间距'),
                Tab(text: '系统'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _sheetPage(_buildStylePage(context)),
                  _sheetPage(_buildTextPage(context)),
                  _sheetPage(_buildSpacingPage(context)),
                  _sheetPage(_buildSystemPage(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(SpacingToken.medium),
              child: FilledButton(
                onPressed: () => widget.onApply(_draft),
                child: const Text('应用'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 为每个设置页提供一致滚动和边距。
  Widget _sheetPage(List<Widget> children) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SpacingToken.medium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// 构建样式页，包含阅读模式和常用配色预设。
  List<Widget> _buildStylePage(BuildContext context) {
    return <Widget>[
      const _ReaderSettingSectionTitle('翻页方式'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: ReaderReadingMode.values.map((ReaderReadingMode mode) {
          return ChoiceChip(
            selected: _draft.readingMode == mode,
            label: Text(_readingModeLabel(mode)),
            onSelected: (bool selected) {
              if (selected) {
                _update(_draft.copyWith(readingMode: mode));
              }
            },
          );
        }).toList(growable: false),
      ),
      const SizedBox(height: SpacingToken.large),
      const _ReaderSettingSectionTitle('翻页动画'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: ReaderPageTurnStyle.values.map((ReaderPageTurnStyle style) {
          return ChoiceChip(
            selected: _draft.pageTurnStyle == style,
            label: Text(_pageTurnStyleLabel(style)),
            onSelected: (bool selected) {
              if (selected) {
                _update(_draft.copyWith(pageTurnStyle: style));
              }
            },
          );
        }).toList(growable: false),
      ),
      const SizedBox(height: SpacingToken.large),
      const _ReaderSettingSectionTitle('阅读配色'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: _themePresets.map(_themeChoice).toList(growable: false),
      ),
    ];
  }

  /// 构建文字页，包含字号、行高、字距、字重和斜体。
  List<Widget> _buildTextPage(BuildContext context) {
    return <Widget>[
      _slider(
        label: '字号 ${_draft.fontSize.toStringAsFixed(0)}',
        value: _draft.fontSize,
        min: 14,
        max: 32,
        divisions: 18,
        onChanged: (double value) => _update(_draft.copyWith(fontSize: value)),
      ),
      _slider(
        label: '行高 ${_draft.lineHeight.toStringAsFixed(1)}',
        value: _draft.lineHeight,
        min: 1.2,
        max: 2.4,
        divisions: 12,
        onChanged: (double value) => _update(_draft.copyWith(lineHeight: value)),
      ),
      _slider(
        label: '字距 ${_draft.letterSpacing.toStringAsFixed(1)}',
        value: _draft.letterSpacing,
        min: 0,
        max: 2,
        divisions: 20,
        onChanged: (double value) => _update(_draft.copyWith(letterSpacing: value)),
      ),
      const SizedBox(height: SpacingToken.small),
      const _ReaderSettingSectionTitle('字重'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: <int>[300, 400, 500, 700].map(_fontWeightChoice).toList(growable: false),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.textItalic,
        title: const Text('斜体'),
        onChanged: (bool value) => _update(_draft.copyWith(textItalic: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.textShadow,
        title: const Text('文字阴影'),
        onChanged: (bool value) => _update(_draft.copyWith(textShadow: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.textUnderline,
        title: const Text('文字下划线'),
        onChanged: (bool value) => _update(_draft.copyWith(textUnderline: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.textFullJustify,
        title: const Text('两端对齐'),
        subtitle: const Text('段落末行保持自然宽度'),
        onChanged: (bool value) => _update(_draft.copyWith(textFullJustify: value)),
      ),
      const SizedBox(height: SpacingToken.medium),
      const _ReaderSettingSectionTitle('章节标题'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: ReaderTitleMode.values.map((ReaderTitleMode mode) {
          return ChoiceChip(
            selected: _draft.titleMode == mode,
            label: Text(_titleModeLabel(mode)),
            onSelected: (bool selected) {
              if (selected) {
                _update(_draft.copyWith(titleMode: mode));
              }
            },
          );
        }).toList(growable: false),
      ),
      _slider(
        label: '标题字号 +${_draft.titleFontSizeOffset.toStringAsFixed(0)}',
        value: _draft.titleFontSizeOffset,
        min: 0,
        max: 16,
        divisions: 16,
        onChanged: (double value) =>
            _update(_draft.copyWith(titleFontSizeOffset: value)),
      ),
      const _ReaderSettingSectionTitle('标题字重'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: <int>[300, 400, 500, 600, 700]
            .map(_titleFontWeightChoice)
            .toList(growable: false),
      ),
    ];
  }

  /// 构建间距页，包含段距和正文四周留白。
  List<Widget> _buildSpacingPage(BuildContext context) {
    return <Widget>[
      _slider(
        label: '段距 ${_draft.paragraphSpacing.toStringAsFixed(0)}',
        value: _draft.paragraphSpacing,
        min: 0,
        max: 32,
        divisions: 16,
        onChanged: (double value) => _update(_draft.copyWith(paragraphSpacing: value)),
      ),
      _slider(
        label: '左右边距 ${_draft.horizontalPadding.toStringAsFixed(0)}',
        value: _draft.horizontalPadding,
        min: 8,
        max: 56,
        divisions: 24,
        onChanged: (double value) => _update(_draft.copyWith(horizontalPadding: value)),
      ),
      _slider(
        label: '上下边距 ${_draft.verticalPadding.toStringAsFixed(0)}',
        value: _draft.verticalPadding,
        min: 8,
        max: 72,
        divisions: 32,
        onChanged: (double value) => _update(_draft.copyWith(verticalPadding: value)),
      ),
      _slider(
        label: '首行缩进 ${_draft.paragraphIndent} 字',
        value: _draft.paragraphIndent.toDouble(),
        min: 0,
        max: 8,
        divisions: 8,
        onChanged: (double value) =>
            _update(_draft.copyWith(paragraphIndent: value.round())),
      ),
      const SizedBox(height: SpacingToken.medium),
      const _ReaderSettingSectionTitle('章节标题留白'),
      _slider(
        label: '标题上方 ${_draft.titleTopSpacing.toStringAsFixed(0)}',
        value: _draft.titleTopSpacing,
        min: 0,
        max: 48,
        divisions: 24,
        onChanged: (double value) =>
            _update(_draft.copyWith(titleTopSpacing: value)),
      ),
      _slider(
        label: '标题下方 ${_draft.titleBottomSpacing.toStringAsFixed(0)}',
        value: _draft.titleBottomSpacing,
        min: 0,
        max: 48,
        divisions: 24,
        onChanged: (double value) =>
            _update(_draft.copyWith(titleBottomSpacing: value)),
      ),
    ];
  }

  /// 构建系统页，保留当前已经真实接入的系统能力和后续边界。
  List<Widget> _buildSystemPage(BuildContext context) {
    /// 设置面板允许选择的 Android 对齐预下载数量。
    const List<int> preDownloadOptions = <int>[0, 2, 5, 10, 20];
    return <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.useReplaceRules,
        title: const Text('应用替换规则'),
        subtitle: const Text('关闭后从原始正文缓存重新生成显示内容'),
        onChanged: (bool value) => _update(_draft.copyWith(useReplaceRules: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.keepScreenOn,
        title: const Text('阅读时保持屏幕常亮'),
        onChanged: (bool value) => _update(_draft.copyWith(keepScreenOn: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.showHeaderFooter,
        title: const Text('显示页眉页脚'),
        onChanged: (bool value) => _update(_draft.copyWith(showHeaderFooter: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.showClock,
        title: const Text('页眉页脚显示时间'),
        onChanged: (bool value) => _update(_draft.copyWith(showClock: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.showBattery,
        title: const Text('页眉页脚显示电量'),
        onChanged: (bool value) => _update(_draft.copyWith(showBattery: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.showMenuToolLabels,
        title: const Text('底部工具显示文字'),
        onChanged: (bool value) => _update(_draft.copyWith(showMenuToolLabels: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.volumeKeyTurnPage,
        title: const Text('音量键翻页'),
        subtitle: const Text('音量加为上一页，音量减为下一页'),
        onChanged: (bool value) => _update(_draft.copyWith(volumeKeyTurnPage: value)),
      ),
      const SizedBox(height: SpacingToken.medium),
      const _ReaderSettingSectionTitle('点击区域'),
      _tapActionTile(
        label: '左侧点击',
        value: _draft.leftTapAction,
        onChanged: (ReaderTapAction action) =>
            _update(_draft.copyWith(leftTapAction: action)),
      ),
      _tapActionTile(
        label: '中间点击',
        value: _draft.centerTapAction,
        onChanged: (ReaderTapAction action) =>
            _update(_draft.copyWith(centerTapAction: action)),
      ),
      _tapActionTile(
        label: '右侧点击',
        value: _draft.rightTapAction,
        onChanged: (ReaderTapAction action) =>
            _update(_draft.copyWith(rightTapAction: action)),
      ),
      _tapActionTile(
        label: '长按正文',
        value: _draft.longPressAction,
        onChanged: (ReaderTapAction action) =>
            _update(_draft.copyWith(longPressAction: action)),
      ),
      _slider(
        label: '左侧宽度 ${(_draft.leftTapWidthRatio * 100).round()}%',
        value: _draft.leftTapWidthRatio,
        min: 0.15,
        max: 0.45,
        divisions: 6,
        onChanged: (double value) =>
            _update(_draft.copyWith(leftTapWidthRatio: value)),
      ),
      _slider(
        label: '右侧宽度 ${(_draft.rightTapWidthRatio * 100).round()}%',
        value: _draft.rightTapWidthRatio,
        min: 0.15,
        max: 0.45,
        divisions: 6,
        onChanged: (double value) =>
            _update(_draft.copyWith(rightTapWidthRatio: value)),
      ),
      const SizedBox(height: SpacingToken.small),
      const _ReaderSettingSectionTitle('预下载章节'),
      Wrap(
        spacing: SpacingToken.small,
        runSpacing: SpacingToken.small,
        children: preDownloadOptions.map((int value) {
          return ChoiceChip(
            selected: _draft.preDownloadCount == value,
            label: Text(value == 0 ? '关闭' : '$value 章'),
            onSelected: (bool selected) {
              if (selected) {
                _update(_draft.copyWith(preDownloadCount: value));
              }
            },
          );
        }).toList(growable: false),
      ),
      const SizedBox(height: SpacingToken.medium),
      const _ReaderSettingSectionTitle('亮度和方向'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _draft.useSystemBrightness,
        title: const Text('跟随系统亮度'),
        onChanged: (bool value) => _update(_draft.copyWith(useSystemBrightness: value)),
      ),
      _slider(
        label: '阅读亮度 ${(_draft.readerBrightness * 100).round()}%',
        value: _draft.readerBrightness,
        min: 0.05,
        max: 1,
        divisions: 19,
        onChanged: _draft.useSystemBrightness
            ? (double value) => _update(_draft.copyWith(readerBrightness: value))
            : (double value) => _update(_draft.copyWith(readerBrightness: value)),
      ),
      DropdownButtonFormField<ReaderOrientationMode>(
        value: _draft.orientationMode,
        decoration: const InputDecoration(labelText: '方向锁定'),
        items: ReaderOrientationMode.values.map((ReaderOrientationMode mode) {
          return DropdownMenuItem<ReaderOrientationMode>(
            value: mode,
            child: Text(_orientationModeLabel(mode)),
          );
        }).toList(growable: false),
        onChanged: (ReaderOrientationMode? mode) {
          if (mode == null) {
            return;
          }
          _update(_draft.copyWith(orientationMode: mode));
        },
      ),
    ];
  }

  /// 构建正文触控动作下拉项。
  Widget _tapActionTile({
    required String label,
    required ReaderTapAction value,
    required ValueChanged<ReaderTapAction> onChanged,
  }) {
    return DropdownButtonFormField<ReaderTapAction>(
      value: value,
      decoration: InputDecoration(labelText: label),
      items: ReaderTapAction.values.map((ReaderTapAction action) {
        return DropdownMenuItem<ReaderTapAction>(
          value: action,
          child: Text(_tapActionLabel(action)),
        );
      }).toList(growable: false),
      onChanged: (ReaderTapAction? action) {
        if (action == null) {
          return;
        }
        onChanged(action);
      },
    );
  }

  /// 构建带标签的显示配置滑杆。
  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 构建一个阅读主题预设选项。
  Widget _themeChoice(_ReaderThemePreset preset) {
    /// 当前是否选择该配色。
    final bool selected = _draft.backgroundColorValue == preset.backgroundColorValue &&
        _draft.textColorValue == preset.textColorValue;
    return ChoiceChip(
      selected: selected,
      avatar: CircleAvatar(backgroundColor: Color(preset.backgroundColorValue)),
      label: Text(preset.label),
      onSelected: (bool value) {
        if (value) {
          _update(
            _draft.copyWith(
              backgroundColorValue: preset.backgroundColorValue,
              textColorValue: preset.textColorValue,
            ),
          );
        }
      },
    );
  }

  /// 构建一个正文粗细选项。
  Widget _fontWeightChoice(int value) {
    return ChoiceChip(
      selected: _draft.fontWeightValue == value,
      label: Text(_fontWeightLabel(value)),
      onSelected: (bool selected) {
        if (selected) {
          _update(_draft.copyWith(fontWeightValue: value));
        }
      },
    );
  }

  /// 构建一个独立于正文的章节标题粗细选项。
  Widget _titleFontWeightChoice(int value) {
    return ChoiceChip(
      selected: _draft.titleFontWeightValue == value,
      label: Text(_fontWeightLabel(value)),
      onSelected: (bool selected) {
        if (selected) {
          _update(_draft.copyWith(titleFontWeightValue: value));
        }
      },
    );
  }

  /// 返回阅读呈现方式的用户可见名称。
  String _readingModeLabel(ReaderReadingMode mode) {
    return switch (mode) {
      ReaderReadingMode.continuous => '连续滚动',
      ReaderReadingMode.horizontalPaging => '左右翻页',
      ReaderReadingMode.verticalPaging => '上下翻页',
    };
  }

  /// 返回翻页动画策略的用户可见名称。
  String _pageTurnStyleLabel(ReaderPageTurnStyle style) {
    return switch (style) {
      ReaderPageTurnStyle.cover => '覆盖',
      ReaderPageTurnStyle.none => '无动画',
      ReaderPageTurnStyle.slide => '滑动',
    };
  }

  /// 返回章节标题显示与水平排版方式的用户可见名称。
  String _titleModeLabel(ReaderTitleMode mode) {
    return switch (mode) {
      ReaderTitleMode.left => '左对齐',
      ReaderTitleMode.center => '居中',
      ReaderTitleMode.hidden => '隐藏',
    };
  }

  /// 阅读触控动作的用户可见名称。
  String _tapActionLabel(ReaderTapAction action) {
    return switch (action) {
      ReaderTapAction.none => '无动作',
      ReaderTapAction.previousPage => '上一页',
      ReaderTapAction.nextPage => '下一页',
      ReaderTapAction.toggleMenu => '显示/隐藏菜单',
      ReaderTapAction.addBookmark => '添加书签',
    };
  }

  /// 阅读方向锁定策略的用户可见名称。
  String _orientationModeLabel(ReaderOrientationMode mode) {
    return switch (mode) {
      ReaderOrientationMode.system => '跟随系统',
      ReaderOrientationMode.portrait => '锁定竖屏',
      ReaderOrientationMode.landscape => '锁定横屏',
    };
  }

  /// 返回字重的用户可见名称。
  String _fontWeightLabel(int value) {
    return switch (value) {
      300 => '细',
      500 => '中',
      600 => '半粗',
      700 => '粗',
      _ => '常规',
    };
  }

  /// 更新本地草稿并刷新面板控件。
  void _update(ReaderDisplayConfig config) {
    setState(() {
      _draft = config;
    });
  }
}

/// 阅读主题预设，保存跨平台 ARGB 值而不让领域模型依赖 Flutter Color。
final class _ReaderThemePreset {
  /// 创建阅读主题预设。
  const _ReaderThemePreset({
    required this.label,
    required this.backgroundColorValue,
    required this.textColorValue,
  });

  /// 用户可见名称。
  final String label;

  /// 背景 ARGB 颜色值。
  final int backgroundColorValue;

  /// 正文 ARGB 颜色值。
  final int textColorValue;
}

/// 设置分组标题。
final class _ReaderSettingSectionTitle extends StatelessWidget {
  /// 创建设置分组标题。
  const _ReaderSettingSectionTitle(this.label);

  /// 分组标题文字。
  final String label;

  /// 构建加粗标题。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SpacingToken.small),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall,
      ),
    );
  }
}

/// P1 第一批阅读主题预设。
const List<_ReaderThemePreset> _themePresets = <_ReaderThemePreset>[
  _ReaderThemePreset(
    label: '纸张',
    backgroundColorValue: 0xFFFFFBF2,
    textColorValue: 0xFF2B2925,
  ),
  _ReaderThemePreset(
    label: '护眼',
    backgroundColorValue: 0xFFE7F0DB,
    textColorValue: 0xFF263322,
  ),
  _ReaderThemePreset(
    label: '白底',
    backgroundColorValue: 0xFFFAFAF7,
    textColorValue: 0xFF1F2320,
  ),
  _ReaderThemePreset(
    label: '深色',
    backgroundColorValue: 0xFF171A17,
    textColorValue: 0xFFDDE5DA,
  ),
];
