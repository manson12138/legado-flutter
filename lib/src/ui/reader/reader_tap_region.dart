import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 被动监听阅读正文的短按，不参与文字选择、拖动翻页等手势竞技场。
final class ReaderTapRegion extends StatefulWidget {
  /// 创建包裹阅读正文的短按监听区域。
  const ReaderTapRegion({
    required this.onTapUp,
    required this.child,
    this.onSelectionActiveChanged,
    super.key,
  });

  /// 确认是短按后回传松手位置，供阅读器按左右区域分派动作。
  final ValueChanged<Offset> onTapUp;

  /// 向外层翻页手势报告原生文字选区是否激活。
  final ValueChanged<bool>? onSelectionActiveChanged;

  /// 被监听的正文、分页器或滚动列表。
  final Widget child;

  /// 创建仅保存单次指针生命周期的状态。
  @override
  State<ReaderTapRegion> createState() => _ReaderTapRegionState();
}

/// 向短按监听器报告原生文字选区是否仍处于激活状态。
final class ReaderTapRegionSelectionScope extends InheritedWidget {
  /// 创建供内部 SelectionArea 使用的选区状态上报范围。
  const ReaderTapRegionSelectionScope({
    required this.onSelectionChanged,
    required super.child,
    super.key,
  });

  /// 接收当前正文区域是否有有效选区的变化。
  final ValueChanged<bool> onSelectionChanged;

  /// 获取最近的短按监听器选区上报范围；正文不在阅读器内时返回空。
  static ReaderTapRegionSelectionScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<
        ReaderTapRegionSelectionScope>();
  }

  /// 回调实例变化时才通知内部 SelectionArea 重新解析依赖。
  @override
  bool updateShouldNotify(ReaderTapRegionSelectionScope oldWidget) {
    return oldWidget.onSelectionChanged != onSelectionChanged;
  }
}

/// 跟踪主指针的时间和位移，避免长按选词、拖动选区及翻页手势误触菜单。
final class _ReaderTapRegionState extends State<ReaderTapRegion> {
  /// 当前可能构成短按的主指针；非主按键和多指触控不会进入菜单动作。
  _ReaderTapCandidate? _candidate;

  /// 当前是否有原生文字选区或选区菜单；激活时短按只用于交给 SelectionArea 取消选区。
  bool _selectionActive = false;

  /// 同步内部正文 SelectionArea 的选区状态，不触发无关的组件重建。
  void _updateSelectionActive(bool value) {
    if (_selectionActive == value) {
      return;
    }
    _selectionActive = value;
    widget.onSelectionActiveChanged?.call(value);
  }

  /// 记录主按键按下的初始位置与时间。
  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) {
      _candidate = null;
      return;
    }
    _candidate = _ReaderTapCandidate(
      pointer: event.pointer,
      position: event.position,
      timeStamp: event.timeStamp,
      selectionWasActive: _selectionActive,
    );
  }

  /// 超过 Flutter 触摸松弛阈值的移动视为拖动，不再作为点击处理。
  void _handlePointerMove(PointerMoveEvent event) {
    final _ReaderTapCandidate? candidate = _candidate;
    if (candidate == null || candidate.pointer != event.pointer) {
      return;
    }
    if ((event.position - candidate.position).distance > kTouchSlop) {
      candidate.moved = true;
    }
  }

  /// 仅把未移动且未达到长按超时的主指针松手识别为阅读短按。
  void _handlePointerUp(PointerUpEvent event) {
    final _ReaderTapCandidate? candidate = _candidate;
    _candidate = null;
    if (candidate == null || candidate.pointer != event.pointer) {
      return;
    }
    final Duration duration = event.timeStamp - candidate.timeStamp;
    if (candidate.selectionWasActive ||
        candidate.moved ||
        duration >= kLongPressTimeout) {
      return;
    }
    widget.onTapUp(event.localPosition);
  }

  /// 指针取消时丢弃候选，避免后续无关松手触发菜单。
  void _handlePointerCancel(PointerCancelEvent event) {
    if (_candidate?.pointer == event.pointer) {
      _candidate = null;
    }
  }

  /// 使用 Listener 观察事件而非注册手势识别器，确保 SelectionArea 仍可独占长按选词。
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: ReaderTapRegionSelectionScope(
        onSelectionChanged: _updateSelectionActive,
        child: widget.child,
      ),
    );
  }
}

/// 保存一次主指针短按判定所需的最小瞬时信息。
final class _ReaderTapCandidate {
  /// 创建短按候选。
  _ReaderTapCandidate({
    required this.pointer,
    required this.position,
    required this.timeStamp,
    required this.selectionWasActive,
  });

  /// Flutter 分配给当前接触点的唯一编号。
  final int pointer;

  /// 指针按下时的全局坐标。
  final Offset position;

  /// 指针按下相对于本帧的时间戳。
  final Duration timeStamp;

  /// 指针按下时是否已有选区；即使松手前选区被清除，也不派发本次阅读短按。
  final bool selectionWasActive;

  /// 是否已超过点击允许的移动距离。
  bool moved = false;
}
