import 'package:material_ui/material_ui.dart';

/// How a menu or a panel opens. The phone uses a bottom sheet; the desktop app puts its own in [sheetOpener]
/// (a menu at the pointer, a dialog in the middle), so this shared code knows nothing about the desktop.
typedef SheetOpener = Future<Object?> Function(BuildContext context, WidgetBuilder builder, {required bool menu});

/// Set by the desktop app (lib/desktop/sheets.dart); null on the phone.
SheetOpener? sheetOpener;

/// showModalBottomSheet on the phone (same arguments). [menu]: a list of actions on something (a song, an
/// album), which the desktop shows as a context menu where the mouse is; otherwise a panel (choices,
/// settings), which the desktop shows as a dialog.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool menu = false,
  bool useRootNavigator = false,
  bool isScrollControlled = false,
  bool showDragHandle = false,
  bool isDismissible = true,
  bool enableDrag = true,
  BoxConstraints? constraints,
}) async {
  final open = sheetOpener;
  if (open != null) return await open(context, builder, menu: menu) as T?;
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    constraints: constraints,
  );
}
