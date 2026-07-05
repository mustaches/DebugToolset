import sys

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

search_str = '''            if (regfile.addresses != null && regfile.addresses!.isNotEmpty) {
               addrs = addrs.intersection(regfile.addresses!.toSet());
            }'''

replace_str = '''            List<int> validAddrs = [];
            if (regfile.addresses != null) validAddrs.addAll(regfile.addresses!);
            if (regfile.addressMap != null) validAddrs.addAll(regfile.addressMap!.keys);
            if (validAddrs.isNotEmpty) {
               addrs = addrs.intersection(validAddrs.toSet());
            }'''

content = content.replace(search_str, replace_str)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
