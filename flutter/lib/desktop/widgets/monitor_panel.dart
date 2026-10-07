import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

// A tiny floating panel with one button per remote monitor, ordered by the
// physical position of the monitors (left to right) instead of by their index,
// so switching monitors takes a single click. Like the toolbar it can be
// dragged anywhere, pinned (never auto-collapses) and collapsed to a small
// handle. Its state is local to this client and shared by every session.

const double _kButtonSize = 24;
const double _kButtonMargin = 2;
const double _kIconSize = 16;
const double _kHandleWidth = 18;
const Duration _kAutoHideDelay = Duration(milliseconds: 5000);

/// Whether the floating monitor panel is enabled. Local option, default on.
bool isMonitorPanelEnabled() =>
    mainGetLocalBoolOptionSync(kOptionEnableMonitorPanel);

/// Bumped whenever the option is toggled from this window, so panels that are
/// already built pick the change up without a window reload.
final RxInt monitorPanelOptionSerial = 0.obs;

Future<void> setMonitorPanelEnabled(bool enabled) async {
  await mainSetLocalBoolOption(kOptionEnableMonitorPanel, enabled);
  monitorPanelOptionSerial.value++;
}

/// Indices of [displays] sorted by physical position: left to right, and top
/// to bottom for displays that share the same left edge.
List<int> monitorPanelDisplayOrder(List<Display> displays) {
  final order = List<int>.generate(displays.length, (i) => i);
  order.sort((a, b) {
    final byX = displays[a].x.compareTo(displays[b].x);
    if (byX != 0) return byX;
    final byY = displays[a].y.compareTo(displays[b].y);
    if (byY != 0) return byY;
    return a.compareTo(b);
  });
  return order;
}

double _clamp01(double v) => v.isNaN ? 0.0 : v.clamp(0.0, 1.0).toDouble();

/// Persistent state of the panel, stored in the local flutter options like
/// the toolbar pin state.
class MonitorPanelState {
  MonitorPanelState._() {
    _load();
  }

  static MonitorPanelState? _instance;
  static MonitorPanelState get instance => _instance ??= MonitorPanelState._();

  /// A pinned panel never collapses on its own.
  final RxBool pin = true.obs;
  final RxBool collapse = false.obs;

  /// Position as fractions of the free space along each axis, so the panel
  /// keeps its relative place when the window is resized. (0, 0) is the top
  /// left corner and (1, 1) the bottom right one.
  final Rx<Offset> fraction = Rx<Offset>(Offset.zero);

  void _load() {
    final s = bind.getLocalFlutterOption(k: kOptionMonitorPanelState);
    if (s.isEmpty) return;
    try {
      final m = jsonDecode(s);
      if (m is Map) {
        final p = m['pin'];
        if (p is bool) pin.value = p;
        final c = m['collapse'];
        if (c is bool) collapse.value = c;
        final x = m['x'];
        final y = m['y'];
        if (x is num && y is num) {
          fraction.value =
              Offset(_clamp01(x.toDouble()), _clamp01(y.toDouble()));
        }
      }
    } catch (e) {
      debugPrint('Failed to decode monitor panel state ${e.toString()}');
    }
  }

  void save() {
    bind.setLocalFlutterOption(
        k: kOptionMonitorPanelState,
        v: jsonEncode({
          'pin': pin.value,
          'collapse': collapse.value,
          'x': fraction.value.dx,
          'y': fraction.value.dy,
        }));
  }

  void setPin(bool v) {
    if (pin.value == v) return;
    pin.value = v;
    save();
  }

  void setCollapse(bool v) {
    if (collapse.value == v) return;
    collapse.value = v;
    save();
  }
}

class MonitorPanel extends StatefulWidget {
  final String id;
  final FFI ffi;
  // Same contract as [RemoteToolbar]: the page tells the panel when the cursor
  // enters (true) or leaves (false) the remote image.
  final Function(int, Function(bool)) onEnterOrLeaveImageSetter;
  final Function(int) onEnterOrLeaveImageCleaner;

  const MonitorPanel({
    Key? key,
    required this.id,
    required this.ffi,
    required this.onEnterOrLeaveImageSetter,
    required this.onEnterOrLeaveImageCleaner,
  }) : super(key: key);

  @override
  State<MonitorPanel> createState() => _MonitorPanelState();
}

class _MonitorPanelState extends State<MonitorPanel> {
  final _panelKey = GlobalKey(debugLabel: 'monitor_panel');
  final _dragging = false.obs;
  Timer? _autoHideTimer;
  bool _isCursorOverImage = false;
  Size _areaSize = Size.zero;
  Offset _dragStartFraction = Offset.zero;
  Offset _dragDelta = Offset.zero;
  Size _dragFreeSpace = Size.zero;

  MonitorPanelState get state => MonitorPanelState.instance;
  PeerInfo get pi => widget.ffi.ffiModel.pi;

  @override
  void initState() {
    super.initState();
    widget.onEnterOrLeaveImageSetter(identityHashCode(this), (enter) {
      _isCursorOverImage = enter;
      if (enter) _scheduleAutoHide();
    });
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    widget.onEnterOrLeaveImageCleaner(identityHashCode(this));
    super.dispose();
  }

  // Same policy as the toolbar: an unpinned, expanded panel collapses a few
  // seconds after the cursor went back to the remote image.
  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(_kAutoHideDelay, () {
      _autoHideTimer = null;
      if (!mounted) return;
      if (state.pin.isFalse &&
          state.collapse.isFalse &&
          _isCursorOverImage &&
          _dragging.isFalse) {
        state.setCollapse(true);
      }
    });
  }

  void _switchTo(int display) {
    if (CurrentDisplayState.find(widget.id).value == display) return;
    final isChooseDisplayToOpenInNewWindow = pi.isSupportMultiDisplay &&
        bind.sessionGetDisplaysAsIndividualWindows(
                sessionId: widget.ffi.sessionId) ==
            'Y';
    if (isChooseDisplayToOpenInNewWindow) {
      openMonitorInNewTabOrWindow(display, widget.ffi.id, pi);
    } else {
      openMonitorInTheSameTab(display, widget.ffi, pi, updateCursorPos: false);
    }
  }

  void _onPanStart(DragStartDetails details) {
    final ro = _panelKey.currentContext?.findRenderObject();
    final panelSize = (ro is RenderBox && ro.hasSize) ? ro.size : Size.zero;
    _dragFreeSpace = Size(
      math.max(0.0, _areaSize.width - panelSize.width),
      math.max(0.0, _areaSize.height - panelSize.height),
    );
    _dragStartFraction = state.fraction.value;
    _dragDelta = Offset.zero;
    _autoHideTimer?.cancel();
    _dragging.value = true;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragging.isFalse) return;
    _dragDelta += details.delta;
    final fx = _dragFreeSpace.width > 0
        ? _clamp01(_dragStartFraction.dx + _dragDelta.dx / _dragFreeSpace.width)
        : _dragStartFraction.dx;
    final fy = _dragFreeSpace.height > 0
        ? _clamp01(
            _dragStartFraction.dy + _dragDelta.dy / _dragFreeSpace.height)
        : _dragStartFraction.dy;
    state.fraction.value = Offset(fx, fy);
  }

  void _onPanEnd() {
    if (_dragging.isFalse) return;
    _dragging.value = false;
    state.save();
    _scheduleAutoHide();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _areaSize = constraints.biggest;
      return Obx(() {
        // Read the serial first so toggling the option rebuilds the panel.
        monitorPanelOptionSerial.value;
        if (!isMonitorPanelEnabled()) return const Offstage();
        final privacyModeState = PrivacyModeState.find(widget.id);
        if (privacyModeState.value.isNotEmpty &&
            !allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value)) {
          return const Offstage();
        }
        if (pi.displaysCount.value < 2) return const Offstage();
        final collapsed = state.collapse.value;
        final fraction = state.fraction.value;
        if (!collapsed && state.pin.isFalse && _dragging.isFalse) {
          _scheduleAutoHide();
        }
        return Align(
          alignment: Alignment(fraction.dx * 2 - 1, fraction.dy * 2 - 1),
          child: Padding(
            key: _panelKey,
            padding: const EdgeInsets.all(4),
            child: _buildPanel(context, collapsed),
          ),
        );
      });
    });
  }

  Widget _buildPanel(BuildContext context, bool collapsed) {
    final borderRadius = BorderRadius.circular(6);
    final children = <Widget>[_buildDragHandle(context)];
    if (collapsed) {
      children.add(_buildExpandButton());
    } else {
      children.addAll(_buildMonitorButtons());
      children.add(_buildPinButton());
      children.add(_buildCollapseButton());
    }
    return MouseRegion(
      // Opaque, so hovering the panel counts as leaving the remote image.
      opaque: true,
      child: Material(
        elevation: 3,
        shadowColor: MyTheme.color(context).shadow,
        borderRadius: borderRadius,
        color: Theme.of(context)
            .menuBarTheme
            .style
            ?.backgroundColor
            ?.resolve(MaterialState.values.toSet()),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: MyTheme.color(context).border3 ?? MyTheme.border,
              width: 1,
            ),
            borderRadius: borderRadius,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }

  Widget _buildDragHandle(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: (_) => _onPanEnd(),
      onPanCancel: _onPanEnd,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: SizedBox(
          width: _kHandleWidth,
          height: _kButtonSize + _kButtonMargin * 2,
          child: Icon(
            Icons.drag_indicator,
            size: _kIconSize,
            color: MyTheme.color(context).drag_indicator,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMonitorButtons() {
    final order = monitorPanelDisplayOrder(pi.displays);
    final current = CurrentDisplayState.find(widget.id).value;
    final total = order.length;
    return [
      for (var pos = 0; pos < total; pos++)
        _PanelButton(
          tooltip: _monitorTooltip(order[pos], pos, total),
          active: order[pos] == current,
          onPressed: () => _switchTo(order[pos]),
          child: _monitorGlyph('${pos + 1}', order[pos] == current),
        ),
    ];
  }

  // The trailing "#n" is the index the toolbar menu uses, when it differs.
  String _monitorTooltip(int display, int pos, int total) {
    final d = pi.displays[display];
    var text =
        '${translate('Switch display')} ${pos + 1}/$total · ${d.width}x${d.height}';
    if (display != pos) text += ' · #${display + 1}';
    return text;
  }

  Widget _monitorGlyph(String label, bool active) {
    return Stack(
      alignment: Alignment.center,
      children: [
        SvgPicture.asset(
          'assets/screen.svg',
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          width: _kButtonSize,
          height: _kButtonSize,
        ),
        Text(
          label,
          style: TextStyle(
            color: active ? MyTheme.button : Colors.grey[800],
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildPinButton() {
    final pinned = state.pin.value;
    return _PanelButton(
      tooltip: translate(pinned ? 'Unpin monitor panel' : 'Pin monitor panel'),
      active: pinned,
      onPressed: () => state.setPin(!pinned),
      child: SvgPicture.asset(
        pinned ? 'assets/pinned.svg' : 'assets/unpinned.svg',
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        width: _kIconSize,
        height: _kIconSize,
      ),
    );
  }

  Widget _buildCollapseButton() {
    return _PanelButton(
      tooltip: translate('Collapse monitor panel'),
      active: false,
      onPressed: () => state.setCollapse(true),
      child: const Icon(
        Icons.chevron_left,
        size: _kIconSize,
        color: Colors.white,
      ),
    );
  }

  Widget _buildExpandButton() {
    final order = monitorPanelDisplayOrder(pi.displays);
    final pos = order.indexOf(CurrentDisplayState.find(widget.id).value);
    return _PanelButton(
      tooltip: translate('Expand monitor panel'),
      active: true,
      onPressed: () => state.setCollapse(false),
      child: _monitorGlyph(pos >= 0 ? '${pos + 1}' : '*', true),
    );
  }
}

class _PanelButton extends StatefulWidget {
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;
  final Widget child;

  const _PanelButton({
    Key? key,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    required this.child,
  }) : super(key: key);

  @override
  State<_PanelButton> createState() => _PanelButtonState();
}

class _PanelButtonState extends State<_PanelButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (widget.active) {
      color = _hover ? MyTheme.accent : MyTheme.button;
    } else {
      color = (_hover ? Colors.grey[850] : Colors.grey[800])!;
    }
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            width: _kButtonSize,
            height: _kButtonSize,
            margin: const EdgeInsets.all(_kButtonMargin),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Center(child: widget.child),
          ),
        ),
      ),
    );
  }
}
