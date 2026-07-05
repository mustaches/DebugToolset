import sys

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('currentBus!.decoder!.name', 'currentBus!.decoder?.name')

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
