import json
import copy

path = "G:/DebugToolSet/DeviceProtocol/SPI/ADS7038H.Regfile"

with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

for ch in range(8):
    cmd_val = 0x80 | (ch << 3)
    cmd_hex = f"0x{cmd_val:02X}"
    data['commands'][cmd_hex] = {
        "name": f"On-the-fly-CH{ch}-ID",
        "access": "W",
        "description": f"On-the-fly Mode Channel {ch} Selection"
    }

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)

print("Updated ADS7038H.Regfile with On-the-fly commands.")
