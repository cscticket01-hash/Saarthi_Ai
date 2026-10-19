import 'windows_appearance.dart';
import 'package:flutter/material.dart';

class WindowsFeeEditorRow {
  const WindowsFeeEditorRow({required this.id, required this.name, required this.amount, required this.onDelete});
  final int id;
  final TextEditingController name;
  final TextEditingController amount;
  final VoidCallback onDelete;
}

/// Presentation only. Persistence, protected editing and school identity belong
/// to the owner screen; rows have stable IDs while names are freely editable.
class WindowsFeeSettingsLayout extends StatelessWidget {
  const WindowsFeeSettingsLayout({super.key, this.scrollController, required this.classes, required this.selectedClass,
    required this.session, required this.sessions, required this.loading, required this.failed,
    required this.saving, required this.editing, required this.rows, required this.onClass,
    required this.onSession, required this.onAdd, required this.onChanged, required this.onSave,
    required this.onEdit, required this.onCancel, required this.onRetry});
  final ScrollController? scrollController;
  final List<String> classes, sessions;
  final String selectedClass, session;
  final bool loading, failed, saving, editing;
  final List<WindowsFeeEditorRow> rows;
  final ValueChanged<String> onClass, onSession;
  final VoidCallback onAdd, onChanged, onSave, onEdit, onCancel, onRetry;
  static const _navy = Color(0xFF0B1B2E);
  static const _teal = Color(0xFF20E3D0);
  static const _muted = Color(0xFFA5BCD4);
  static const _border = Color(0xFF334D68);

  InputDecoration _input(String hint, {String? prefix}) => InputDecoration(
    hintText: hint,
    prefixIcon: prefix == null ? null : Center(child: Text(prefix.trim(), style:  TextStyle(color: WindowsAppearance.resolve(Colors.white)))),
    prefixIconConstraints: prefix == null ? null : const BoxConstraints(minWidth: 38, maxWidth: 38),
    hintStyle:  TextStyle(color: WindowsAppearance.resolve(_muted)),
    prefixStyle:  TextStyle(color: WindowsAppearance.resolve(Colors.white)), isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    filled: true, fillColor: WindowsAppearance.resolve(const Color(0xFF0D2035)),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide:  BorderSide(color: WindowsAppearance.resolve(_border))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide:  BorderSide(color: WindowsAppearance.resolve(_border))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: _teal, width: 1.5)),
  );

  Widget _selector(BuildContext context, {required String label, required String value,
    required List<String> options, required ValueChanged<String> onChanged}) => InputDecorator(
      decoration: _input(label).copyWith(labelText: label, labelStyle:  TextStyle(color: WindowsAppearance.resolve(_muted))),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: options.contains(value) ? value : null, isExpanded: true, isDense: true,
        dropdownColor: WindowsAppearance.resolve(_navy), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: WindowsAppearance.resolve(Colors.white)),
        items: options.map((item) => DropdownMenuItem(value: item, child: Text(item))).toList(),
        onChanged: saving || loading ? null : (value) { if (value != null) onChanged(value); },
      )),
    );

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  Scaffold(
    backgroundColor: WindowsAppearance.resolve(_navy),
    body: DecoratedBox(
      decoration:  BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [WindowsAppearance.resolve(Color(0xFF10233B)), WindowsAppearance.resolve(Color(0xFF071524))])),
      child: SafeArea(child: LayoutBuilder(builder: (context, constraints) {WindowsAppearance.watch(context);
        final wide = constraints.maxWidth >= 1000 && MediaQuery.textScalerOf(context).scale(16) < 25;
        final content = _content(context, wide);
        return Row(children: [
          if (wide) SizedBox(width: 210, child: Container(
            decoration:  BoxDecoration(border: Border(right: BorderSide(color: WindowsAppearance.resolve(_border)))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
               Padding(padding: EdgeInsets.fromLTRB(22, 28, 16, 24), child: Text('Vidya Saarthi',
                style: TextStyle(color: WindowsAppearance.resolve(Colors.white), fontSize: 22, fontWeight: FontWeight.w700))),
              Expanded(child: ListView(children: classes.map((item) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Material(color: item == selectedClass ? WindowsAppearance.resolve(const Color(0xFF126C73)) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10), child: ListTile(selected: item == selectedClass,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  title: Text(item, style: TextStyle(color: item == selectedClass ? WindowsAppearance.resolve(Colors.white) : WindowsAppearance.resolve(_muted),
                    fontWeight: item == selectedClass ? FontWeight.w700 : FontWeight.normal)),
                  onTap: saving || loading ? null : () => onClass(item))),
              )).toList())),
            ]),
          )),
          Expanded(child: content),
        ]);
      })),
    ),
  ); }

  Widget _content(BuildContext context, bool wide) => Column(children: [
    Padding(padding: EdgeInsets.fromLTRB(wide ? 22 : 8, 16, 16, 12), child: Row(children: [
      IconButton(tooltip: 'Back', onPressed: saving ? null : () => Navigator.maybePop(context),
        icon:  Icon(Icons.arrow_back, color: WindowsAppearance.resolve(Colors.white))),
      const SizedBox(width: 8),
       Expanded(child: Text('Payment Collection Settings',
        style: TextStyle(color: WindowsAppearance.resolve(Colors.white), fontSize: 23, fontWeight: FontWeight.w700))),
    ])),
    Expanded(child: loading ? const Center(child: CircularProgressIndicator(color: _teal))
      : failed ? Center(child: FilledButton(onPressed: onRetry, child: const Text('Retry loading fees')))
      : SingleChildScrollView(controller: scrollController, padding: EdgeInsets.fromLTRB(wide ? 40 : 16, 12, wide ? 40 : 16, 24),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1150),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!wide) ...[
              _selector(context, label: 'Class', value: selectedClass, options: classes, onChanged: onClass),
              const SizedBox(height: 20),
            ],
            Flex(direction: wide ? Axis.horizontal : Axis.vertical, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (wide) Expanded(child: _heading()) else _heading(),
              if (!wide) const SizedBox(height: 20),
              SizedBox(width: wide ? 220 : double.infinity, child: _selector(context,
                label: 'Academic session', value: session, options: sessions, onChanged: onSession)),
            ]),
            const SizedBox(height: 24),
            Container(padding: EdgeInsets.all(wide ? 24 : 14),
              decoration: BoxDecoration(color: WindowsAppearance.resolve(const Color(0xFF102338)), borderRadius: BorderRadius.circular(15),
                border: Border.all(color: WindowsAppearance.resolve(_border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 12,
                  children: [ Text('Fee details', style: TextStyle(color: WindowsAppearance.resolve(Colors.white), fontSize: 22, fontWeight: FontWeight.w700)),
                    if (editing) OutlinedButton.icon(key: const ValueKey('add-fee'), onPressed: saving ? null : onAdd,
                      style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), foregroundColor: _teal, side: const BorderSide(color: _teal)),
                      icon: const Icon(Icons.add), label: const Text('Add fee')),
                  ]),
                 Divider(height: 28, color: WindowsAppearance.resolve(_border)),
                if (wide)  Padding(padding: EdgeInsets.only(left: 44, bottom: 12), child: Row(children: [
                  Expanded(flex: 7, child: Text('Fee name', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                  SizedBox(width: 20), Expanded(flex: 3, child: Text('Amount', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                  SizedBox(width: 18), SizedBox(width: 48, child: Text('Action', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                ])),
                if (rows.isEmpty)  Padding(padding: EdgeInsets.all(24), child: Text('No fee rows. Use Add fee to create one.', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                for (var i = 0; i < rows.length; i++) Padding(key: ValueKey('fee-row-${rows[i].id}'),
                  padding: const EdgeInsets.only(bottom: 10), child: _row(rows[i], i, wide)),
                 Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Blank or zero amounts stay hidden in collection.', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                 Divider(color: WindowsAppearance.resolve(_border)),
                const SizedBox(height: 12),
                Wrap(alignment: WrapAlignment.end, spacing: 16, runSpacing: 12, children: [
                  if (editing) TextButton(onPressed: saving ? null : onCancel, child:  Text('Cancel', style: TextStyle(color: WindowsAppearance.resolve(_muted)))),
                  FilledButton.icon(onPressed: saving ? null : editing ? onSave : onEdit,
                    style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), backgroundColor: _teal, foregroundColor: WindowsAppearance.resolve(const Color(0xFF05202A)),
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18)),
                    icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(editing ? Icons.save_outlined : Icons.lock_open),
                    label: Text(saving ? 'Saving...' : editing ? 'Save changes' : 'Edit Fee Structure')),
                ]),
              ]),
            ),
          ]),
        )),
      )),
  ]);

  Widget _heading() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('$selectedClass Fee Structure', style:  TextStyle(color: WindowsAppearance.resolve(Colors.white), fontSize: 28, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    Text(editing ? 'Add, edit or remove fees for your school.' : 'Saved and locked. Use Edit Fee Structure to make changes.',
      style:  TextStyle(color: WindowsAppearance.resolve(_muted), fontSize: 15)),
  ]);

  Widget _row(WindowsFeeEditorRow row, int index, bool wide) {
    final name = editing ? TextField(key: ValueKey('fee-name-${row.id}'), controller: row.name,
      enabled: !saving, maxLength: 100, style:  TextStyle(color: WindowsAppearance.resolve(Colors.white)),
      onChanged: (_) => onChanged(), decoration: _input('Enter fee name').copyWith(counterText: ''))
      : Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(row.name.text, style:  TextStyle(color: WindowsAppearance.resolve(Colors.white))));
    final amount = editing ? TextField(key: ValueKey('fee-amount-${row.id}'), controller: row.amount,
      enabled: !saving, keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style:  TextStyle(color: WindowsAppearance.resolve(Colors.white)), onChanged: (_) => onChanged(), decoration: _input('Amount', prefix: '₹ '))
      : Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text('₹ ${row.amount.text.isEmpty ? '0' : row.amount.text}', style:  TextStyle(color: WindowsAppearance.resolve(Colors.white))));
    final action = SizedBox(width: 48, child: editing ? IconButton.outlined(key: ValueKey('delete-fee-${row.id}'),
      tooltip: 'Delete fee row ${index + 1}', onPressed: saving ? null : row.onDelete,
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), foregroundColor: const Color(0xFFFF5B6C), side: const BorderSide(color: Color(0xFFAF4054))),
      icon: const Icon(Icons.delete_outline)) : const SizedBox());
    if (!wide) return Container(padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: WindowsAppearance.resolve(_border)), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [name, const SizedBox(height: 10),
        Row(children: [Expanded(child: amount), const SizedBox(width: 12), action]) ]));
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 44, child: Text('${index + 1}'.padLeft(2, '0'), style:  TextStyle(color: WindowsAppearance.resolve(_muted)))),
      Expanded(flex: 7, child: name), const SizedBox(width: 20), Expanded(flex: 3, child: amount),
      const SizedBox(width: 18), action,
    ]);
  }
}
