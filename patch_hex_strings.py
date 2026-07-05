import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix _cachedI2cDevices
content = content.replace(
    "_cachedI2cDevices.map((addr) {\n                                       String hex = '0x';",
    "_cachedI2cDevices.map((addr) {\n                                       String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, \"0\")}';"
)

# Fix _cachedI2cRegisters
content = content.replace(
    "_cachedI2cRegisters.map((addr) {\n                                             String hex = '0x';",
    "_cachedI2cRegisters.map((addr) {\n                                             String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, \"0\")}';"
)

# Fix _cachedSpiCommands
content = content.replace(
    "_cachedSpiCommands.map((cmd) {\n                                       String hex = '0x';",
    "_cachedSpiCommands.map((cmd) {\n                                       String hex = '0x${cmd.toRadixString(16).toUpperCase().padLeft(2, \"0\")}';"
)

# Fix _cachedSpiAddresses
content = content.replace(
    "_cachedSpiAddresses.map((addr) {\n                                             String hex = '0x';",
    "_cachedSpiAddresses.map((addr) {\n                                             String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, \"0\")}';"
)

# Fix No Match labels
content = re.sub(
    r"Text\('0x \(无匹\?No match\)'",
    r"Text('0x${_i2cDeviceAddress?.toRadixString(16).toUpperCase().padLeft(2, \"0\")} (无匹配/No match)'",
    content, count=1
)
content = re.sub(
    r"Text\('0x \(无匹\?No match\)'",
    r"Text('0x${_i2cRegisterAddress?.toRadixString(16).toUpperCase().padLeft(2, \"0\")} (无匹配/No match)'",
    content, count=1
)
content = re.sub(
    r"Text\('0x \(无匹\?No match\)'",
    r"Text('0x${_spiCommand?.toRadixString(16).toUpperCase().padLeft(2, \"0\")} (无匹配/No match)'",
    content, count=1
)
content = re.sub(
    r"Text\('0x \(无匹\?No match\)'",
    r"Text('0x${_spiAddress?.toRadixString(16).toUpperCase().padLeft(2, \"0\")} (无匹配/No match)'",
    content, count=1
)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
