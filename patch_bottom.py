import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace the condition at the bottom so Format/Value row only shows for buses that don't have their own 
# Specifically, we want it for generic buses (no decoder)
search = "if (!disableInput && !isRawUart && !isUartWithProtocol) ...["
replace = "if (!disableInput && !isRawUart && !isUartWithProtocol && !isI2c && !(hasDecoder && currentBus!.decoder?.name == 'SPI')) ...["
content = content.replace(search, replace)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
