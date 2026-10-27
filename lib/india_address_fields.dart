import 'package:flutter/material.dart';
import 'india_locations.dart';
import 'windows_appearance.dart';

/// Local form controls only. The existing record owner saves and syncs values.
class IndiaAddressFields extends StatefulWidget {
  const IndiaAddressFields({super.key, required this.country, required this.state,
    required this.district, this.enabled = true});
  final TextEditingController country, state, district;
  final bool enabled;
  @override
  State<IndiaAddressFields> createState() => _IndiaAddressFieldsState();
}

class _IndiaAddressFieldsState extends State<IndiaAddressFields> {
  Future<String?> _choose(String title, List<String> options) => showDialog<String>(
    context: context,
    builder: (context) {
      var query = '';
      return StatefulBuilder(builder: (context, update) {
        final matches = options.where((v) => v.toLowerCase().contains(query.toLowerCase())).toList();
        return AlertDialog(
          title: Text('Select $title'),
          content: SizedBox(width: 420, height: 360, child: Column(children: [
            TextField(autofocus: true, decoration: InputDecoration(labelText: 'Search $title'),
              onChanged: (value) => update(() => query = value)),
            const SizedBox(height: 8),
            Expanded(child: ListView.builder(itemCount: matches.length, itemBuilder: (context, index) =>
              ListTile(title: Text(matches[index]), onTap: () => Navigator.pop(context, matches[index])))),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
        );
      });
    },
  );

  Widget _field(String label, TextEditingController controller, VoidCallback? tap) => TextField(
    key: ValueKey('address-${label.toLowerCase()}'), controller: controller, readOnly: true,
    enabled: widget.enabled, onTap: tap,
    style: TextStyle(color: WindowsAppearance.resolve(Colors.white)),
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(),
      suffixIcon: tap == null ? null : const Icon(Icons.arrow_drop_down)),
  );

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _field('Country', widget.country, null),
      const SizedBox(height: 10),
      _field('State', widget.state, widget.enabled ? () async {
        final selected = await _choose('State', indiaDistricts.keys.toList());
        if (!mounted || !widget.enabled || selected == null || selected == widget.state.text) return;
        setState(() {
          widget.country.text = 'India';
          widget.state.text = selected;
          widget.district.clear();
        });
      } : null),
      const SizedBox(height: 10),
      _field('District', widget.district,
        widget.enabled && indiaDistricts.containsKey(widget.state.text) ? () async {
          final state = widget.state.text;
          final selected = await _choose('District', indiaDistricts[state]!);
          if (!mounted || !widget.enabled || state != widget.state.text || selected == null) return;
          setState(() => widget.district.text = selected);
        } : null),
      if (!indiaDistricts.containsKey(widget.state.text))
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('Select a State to choose its District.')),
    ]);
  }
}
