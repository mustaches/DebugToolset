import sys

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('\ufeff', '')
content = content.replace('else if (isSpi) ...[', "else if (hasDecoder && currentBus!.decoder!.name == 'SPI') ...[")

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
