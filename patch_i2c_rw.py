import sys

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace("startsWith('Read')", "startsWith('R')")
content = content.replace("startsWith('Write')", "startsWith('W')")

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
