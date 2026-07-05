import fitz
import json
import re

pdf_path = "G:/DebugToolSet/datasheet/ADS7038H.pdf"
doc = fitz.open(pdf_path)

out = {
    "name": "ADS7038H",
    "hasSubaddress": True,
    "commands": {
        "0x00": {
            "name": "NOP",
            "access": "W",
            "description": "No operation"
        },
        "0x08": {
            "name": "Write",
            "access": "W",
            "description": "Single register write"
        },
        "0x10": {
            "name": "Read",
            "access": "R",
            "description": "Single register read"
        },
        "0x18": {
            "name": "Set Bit",
            "access": "W",
            "description": "Set bit in register"
        },
        "0x20": {
            "name": "Clear Bit",
            "access": "W",
            "description": "Clear bit in register"
        }
    },
    "registers": {}
}

# Define the basic registers from Table 8-1
registers_raw = """
0x0 SYSTEM_STATUS SYSTEM_STATUS Register (Address = 0x0) [reset = 0x81]
0x1 GENERAL_CFG GENERAL_CFG Register (Address = 0x1) [reset = 0x0]
0x2 DATA_CFG DATA_CFG Register (Address = 0x2) [reset = 0x0]
0x3 OSR_CFG OSR_CFG Register (Address = 0x3) [reset = 0x0]
0x4 OPMODE_CFG OPMODE_CFG Register (Address = 0x4) [reset = 0x0]
0x5 PIN_CFG PIN_CFG Register (Address = 0x5) [reset = 0x0]
0x7 GPIO_CFG GPIO_CFG Register (Address = 0x7) [reset = 0x0]
0x9 GPO_DRIVE_CFG GPO_DRIVE_CFG Register (Address = 0x9) [reset = 0x0]
0xB GPO_VALUE GPO_VALUE Register (Address = 0xB) [reset = 0x0]
0xD GPI_VALUE GPI_VALUE Register (Address = 0xD) [reset = 0x0]
0x10 SEQUENCE_CFG SEQUENCE_CFG Register (Address = 0x10) [reset = 0x0]
0x11 CHANNEL_SEL CHANNEL_SEL Register (Address = 0x11) [reset = 0x0]
0x12 AUTO_SEQ_CH_SEL AUTO_SEQ_CH_SEL Register (Address = 0x12) [reset = 0x0]
0x14 ALERT_CH_SEL ALERT_CH_SEL Register (Address = 0x14) [reset = 0x0]
0x16 ALERT_MAP ALERT_MAP Register (Address = 0x16) [reset = 0x0]
0x17 ALERT_PIN_CFG ALERT_PIN_CFG Register (Address = 0x17) [reset = 0x0]
0x18 EVENT_FLAG EVENT_FLAG Register (Address = 0x18) [reset = 0x0]
0x1A EVENT_HIGH_FLAG EVENT_HIGH_FLAG Register (Address = 0x1A) [reset = 0x0]
0x1C EVENT_LOW_FLAG EVENT_LOW_FLAG Register (Address = 0x1C) [reset = 0x0]
0x1E EVENT_RGN EVENT_RGN Register (Address = 0x1E) [reset = 0x0]
0x20 HYSTERESIS_CH0 HYSTERESIS_CH0 Register (Address = 0x20) [reset = 0xF0]
0x21 HIGH_TH_CH0 HIGH_TH_CH0 Register (Address = 0x21) [reset = 0xFF]
0x22 EVENT_COUNT_CH0 EVENT_COUNT_CH0 Register (Address = 0x22) [reset = 0x0]
0x23 LOW_TH_CH0 LOW_TH_CH0 Register (Address = 0x23) [reset = 0x0]
0x24 HYSTERESIS_CH1 HYSTERESIS_CH1 Register (Address = 0x24) [reset = 0xF0]
0x25 HIGH_TH_CH1 HIGH_TH_CH1 Register (Address = 0x25) [reset = 0xFF]
0x26 EVENT_COUNT_CH1 EVENT_COUNT_CH1 Register (Address = 0x26) [reset = 0x0]
0x27 LOW_TH_CH1 LOW_TH_CH1 Register (Address = 0x27) [reset = 0x0]
0x28 HYSTERESIS_CH2 HYSTERESIS_CH2 Register (Address = 0x28) [reset = 0xF0]
0x29 HIGH_TH_CH2 HIGH_TH_CH2 Register (Address = 0x29) [reset = 0xFF]
0x2A EVENT_COUNT_CH2 EVENT_COUNT_CH2 Register (Address = 0x2A) [reset = 0x0]
0x2B LOW_TH_CH2 LOW_TH_CH2 Register (Address = 0x2B) [reset = 0x0]
0x2C HYSTERESIS_CH3 HYSTERESIS_CH3 Register (Address = 0x2C) [reset = 0xF0]
0x2D HIGH_TH_CH3 HIGH_TH_CH3 Register (Address = 0x2D) [reset = 0xFF]
0x2E EVENT_COUNT_CH3 EVENT_COUNT_CH3 Register (Address = 0x2E) [reset = 0x0]
0x2F LOW_TH_CH3 LOW_TH_CH3 Register (Address = 0x2F) [reset = 0x0]
0x30 HYSTERESIS_CH4 HYSTERESIS_CH4 Register (Address = 0x30) [reset = 0xF0]
0x31 HIGH_TH_CH4 HIGH_TH_CH4 Register (Address = 0x31) [reset = 0xFF]
0x32 EVENT_COUNT_CH4 EVENT_COUNT_CH4 Register (Address = 0x32) [reset = 0x0]
0x33 LOW_TH_CH4 LOW_TH_CH4 Register (Address = 0x33) [reset = 0x0]
0x34 HYSTERESIS_CH5 HYSTERESIS_CH5 Register (Address = 0x34) [reset = 0xF0]
0x35 HIGH_TH_CH5 HIGH_TH_CH5 Register (Address = 0x35) [reset = 0xFF]
0x36 EVENT_COUNT_CH5 EVENT_COUNT_CH5 Register (Address = 0x36) [reset = 0x0]
0x37 LOW_TH_CH5 LOW_TH_CH5 Register (Address = 0x37) [reset = 0x0]
0x38 HYSTERESIS_CH6 HYSTERESIS_CH6 Register (Address = 0x38) [reset = 0xF0]
0x39 HIGH_TH_CH6 HIGH_TH_CH6 Register (Address = 0x39) [reset = 0xFF]
0x3A EVENT_COUNT_CH6 EVENT_COUNT_CH6 Register (Address = 0x3A) [reset = 0x0]
0x3B LOW_TH_CH6 LOW_TH_CH6 Register (Address = 0x3B) [reset = 0x0]
0x3C HYSTERESIS_CH7 HYSTERESIS_CH7 Register (Address = 0x3C) [reset = 0xF0]
0x3D HIGH_TH_CH7 HIGH_TH_CH7 Register (Address = 0x3D) [reset = 0xFF]
0x3E EVENT_COUNT_CH7 EVENT_COUNT_CH7 Register (Address = 0x3E) [reset = 0x0]
0x3F LOW_TH_CH7 LOW_TH_CH7 Register (Address = 0x3F) [reset = 0x0]
0x60 MAX_CH0_LSB MAX_CH0_LSB Register (Address = 0x60) [reset = 0x0]
0x61 MAX_CH0_MSB MAX_CH0_MSB Register (Address = 0x61) [reset = 0x0]
0x62 MAX_CH1_LSB MAX_CH1_LSB Register (Address = 0x62) [reset = 0x0]
0x63 MAX_CH1_MSB MAX_CH1_MSB Register (Address = 0x63) [reset = 0x0]
0x64 MAX_CH2_LSB MAX_CH2_LSB Register (Address = 0x64) [reset = 0x0]
0x65 MAX_CH2_MSB MAX_CH2_MSB Register (Address = 0x65) [reset = 0x0]
0x66 MAX_CH3_LSB MAX_CH3_LSB Register (Address = 0x66) [reset = 0x0]
0x67 MAX_CH3_MSB MAX_CH3_MSB Register (Address = 0x67) [reset = 0x0]
0x68 MAX_CH4_LSB MAX_CH4_LSB Register (Address = 0x68) [reset = 0x0]
0x69 MAX_CH4_MSB MAX_CH4_MSB Register (Address = 0x69) [reset = 0x0]
0x6A MAX_CH5_LSB MAX_CH5_LSB Register (Address = 0x6A) [reset = 0x0]
0x6B MAX_CH5_MSB MAX_CH5_MSB Register (Address = 0x6B) [reset = 0x0]
0x6C MAX_CH6_LSB MAX_CH6_LSB Register (Address = 0x6C) [reset = 0x0]
0x6D MAX_CH6_MSB MAX_CH6_MSB Register (Address = 0x6D) [reset = 0x0]
0x6E MAX_CH7_LSB MAX_CH7_LSB Register (Address = 0x6E) [reset = 0x0]
0x6F MAX_CH7_MSB MAX_CH7_MSB Register (Address = 0x6F) [reset = 0x0]
0x80 MIN_CH0_LSB MIN_CH0_LSB Register (Address = 0x80) [reset = 0xFF]
0x81 MIN_CH0_MSB MIN_CH0_MSB Register (Address = 0x81) [reset = 0xFF]
0x82 MIN_CH1_LSB MIN_CH1_LSB Register (Address = 0x82) [reset = 0xFF]
0x83 MIN_CH1_MSB MIN_CH1_MSB Register (Address = 0x83) [reset = 0xFF]
0x84 MIN_CH2_LSB MIN_CH2_LSB Register (Address = 0x84) [reset = 0xFF]
0x85 MIN_CH2_MSB MIN_CH2_MSB Register (Address = 0x85) [reset = 0xFF]
0x86 MIN_CH3_LSB MIN_CH3_LSB Register (Address = 0x86) [reset = 0xFF]
0x87 MIN_CH3_MSB MIN_CH3_MSB Register (Address = 0x87) [reset = 0xFF]
0x88 MIN_CH4_LSB MIN_CH4_LSB Register (Address = 0x88) [reset = 0xFF]
0x89 MIN_CH4_MSB MIN_CH4_MSB Register (Address = 0x89) [reset = 0xFF]
0x8A MIN_CH5_LSB MIN_CH5_LSB Register (Address = 0x8A) [reset = 0xFF]
0x8B MIN_CH5_MSB MIN_CH5_MSB Register (Address = 0x8B) [reset = 0xFF]
0x8C MIN_CH6_LSB MIN_CH6_LSB Register (Address = 0x8C) [reset = 0xFF]
0x8D MIN_CH6_MSB MIN_CH6_MSB Register (Address = 0x8D) [reset = 0xFF]
0x8E MIN_CH7_LSB MIN_CH7_LSB Register (Address = 0x8E) [reset = 0xFF]
0x8F MIN_CH7_MSB MIN_CH7_MSB Register (Address = 0x8F) [reset = 0xFF]
0xA0 RECENT_CH0_LSB RECENT_CH0_LSB Register (Address = 0xA0) [reset = 0x0]
0xA1 RECENT_CH0_MSB RECENT_CH0_MSB Register (Address = 0xA1) [reset = 0x0]
0xA2 RECENT_CH1_LSB RECENT_CH1_LSB Register (Address = 0xA2) [reset = 0x0]
0xA3 RECENT_CH1_MSB RECENT_CH1_MSB Register (Address = 0xA3) [reset = 0x0]
0xA4 RECENT_CH2_LSB RECENT_CH2_LSB Register (Address = 0xA4) [reset = 0x0]
0xA5 RECENT_CH2_MSB RECENT_CH2_MSB Register (Address = 0xA5) [reset = 0x0]
0xA6 RECENT_CH3_LSB RECENT_CH3_LSB Register (Address = 0xA6) [reset = 0x0]
0xA7 RECENT_CH3_MSB RECENT_CH3_MSB Register (Address = 0xA7) [reset = 0x0]
0xA8 RECENT_CH4_LSB RECENT_CH4_LSB Register (Address = 0xA8) [reset = 0x0]
0xA9 RECENT_CH4_MSB RECENT_CH4_MSB Register (Address = 0xA9) [reset = 0x0]
0xAA RECENT_CH5_LSB RECENT_CH5_LSB Register (Address = 0xAA) [reset = 0x0]
0xAB RECENT_CH5_MSB RECENT_CH5_MSB Register (Address = 0xAB) [reset = 0x0]
0xAC RECENT_CH6_LSB RECENT_CH6_LSB Register (Address = 0xAC) [reset = 0x0]
0xAD RECENT_CH6_MSB RECENT_CH6_MSB Register (Address = 0xAD) [reset = 0x0]
0xAE RECENT_CH7_LSB RECENT_CH7_LSB Register (Address = 0xAE) [reset = 0x0]
0xAF RECENT_CH7_MSB RECENT_CH7_MSB Register (Address = 0xAF) [reset = 0x0]
0xC3 GPO0_TRIG_EVENT_SEL GPO0_TRIG_EVENT_SEL Register (Address = 0xC3) [reset = 0x0]
0xC5 GPO1_TRIG_EVENT_SEL GPO1_TRIG_EVENT_SEL Register (Address = 0xC5) [reset = 0x0]
0xC7 GPO2_TRIG_EVENT_SEL GPO2_TRIG_EVENT_SEL Register (Address = 0xC7) [reset = 0x0]
0xC9 GPO3_TRIG_EVENT_SEL GPO3_TRIG_EVENT_SEL Register (Address = 0xC9) [reset = 0x0]
0xCB GPO4_TRIG_EVENT_SEL GPO4_TRIG_EVENT_SEL Register (Address = 0xCB) [reset = 0x0]
0xCD GPO5_TRIG_EVENT_SEL GPO5_TRIG_EVENT_SEL Register (Address = 0xCD) [reset = 0x0]
0xCF GPO6_TRIG_EVENT_SEL GPO6_TRIG_EVENT_SEL Register (Address = 0xCF) [reset = 0x0]
0xD1 GPO7_TRIG_EVENT_SEL GPO7_TRIG_EVENT_SEL Register (Address = 0xD1) [reset = 0x0]
0xE9 GPO_TRIGGER_CFG GPO_TRIGGER_CFG Register (Address = 0xE9) [reset = 0x0]
0xEB GPO_VALUE_TRIG GPO_VALUE_TRIG Register (Address = 0xEB) [reset = 0x0]
"""

# Store base definitions
for line in registers_raw.strip().split('\n'):
    parts = line.split()
    if len(parts) >= 2:
        addr = parts[0]
        if addr.startswith('0x'):
            hex_val = addr[2:]
            addr = f"0x{hex_val.zfill(2)}"
        name = parts[1]
        out["registers"][addr] = {
            "name": name,
            "access": "R/W",
            "description": line,
            "fields": []
        }

# We need to extract the detailed tables from the PDF.
# Let's extract all tables using fitz's table finder.
all_fields = []
current_register = None
current_address = None

# Iterate over all pages
for page_num in range(doc.page_count):
    page = doc[page_num]
    tabs = page.find_tables()
    for tab in tabs:
        rows = tab.extract()
        if not rows:
            continue
        
        header = [str(cell).strip().replace('\n', ' ') for cell in rows[0]]
        
        # Check if this table is a Field Description table
        if "Bit" in header and "Field" in header and "Type" in header and "Reset" in header and "Description" in header:
            
            # This is a bitfield table. But we need to know for WHICH register.
            # Usually the text just above the table indicates the register name or address.
            # Let's find the text block before the table bounding box.
            rect = tab.bbox
            blocks = page.get_text("blocks")
            # Sort blocks by y coordinate
            blocks = sorted(blocks, key=lambda b: b[1])
            reg_name_from_text = None
            reg_addr_from_text = None
            for b in reversed(blocks):
                # Only check blocks above the table
                if b[3] <= rect[1]:
                    txt = b[4].strip()
                    # Look for "8.6.x.x Register_Name Register (Address = 0xXX)"
                    match = re.search(r'Register \(Address\s*=\s*(0x[0-9A-Fa-f]+)\)', txt)
                    if match:
                        reg_addr_from_text = match.group(1).upper()
                        reg_addr_from_text = f"0x{reg_addr_from_text[2:].zfill(2)}" # pad 2
                        break
            
            if reg_addr_from_text and reg_addr_from_text in out["registers"]:
                current_address = reg_addr_from_text
            else:
                continue

            # Parse fields
            for r_idx in range(1, len(rows)):
                row = [str(cell).strip().replace('\n', ' ') for cell in rows[r_idx]]
                if len(row) < 5:
                    continue
                
                bit_str = row[header.index("Bit")]
                field_name = row[header.index("Field")]
                if field_name == "RESERVED" or field_name == "None":
                    continue
                
                access = row[header.index("Type")]
                desc = row[header.index("Description")]
                
                start_bit, end_bit = 0, 0
                if ':' in bit_str:
                    m = re.match(r'(\d+):(\d+)', bit_str)
                    if m:
                        end_bit = int(m.group(1))
                        start_bit = int(m.group(2))
                else:
                    m = re.match(r'(\d+)', bit_str)
                    if m:
                        start_bit = end_bit = int(m.group(1))
                
                # Check for value maps in the description
                valueMap = {}
                # Look for patterns like "0b = ...", "0h = ...", "1b = ...", "00b = ..."
                # Standardize to 0x or int
                lines = desc.split(' ')
                # It's hard to parse exact value maps perfectly without manual curation, 
                # but let's try a regex for something like '0b = Normal operation'
                matches = re.finditer(r'([0-1]+)b\s*=\s*([^0-1][^=]+?)(?=\s+[0-1]+b\s*=|$)', desc + " ")
                for m in matches:
                    val = int(m.group(1), 2)
                    valueMap[str(val)] = m.group(2).strip()
                
                # Also look for hex: 0h =, 1h = 
                if not valueMap:
                    matches_hex = re.finditer(r'([0-9A-Fa-f]+)h\s*=\s*([^0-9A-Fa-f][^=]+?)(?=\s+[0-9A-Fa-f]+h\s*=|$)', desc + " ")
                    for m in matches_hex:
                        val = int(m.group(1), 16)
                        valueMap[str(val)] = m.group(2).strip()

                field_def = {
                    "name": field_name,
                    "startBit": start_bit,
                    "endBit": end_bit,
                    "access": access,
                    "description": desc.strip()
                }
                if valueMap:
                    field_def["valueMap"] = valueMap

                out["registers"][current_address]["fields"].append(field_def)

with open('G:/DebugToolSet/DeviceProtocol/SPI/ADS7038H.Regfile', 'w', encoding='utf-8') as f:
    json.dump(out, f, indent=2)

print("Generated full G:/DebugToolSet/DeviceProtocol/SPI/ADS7038H.Regfile")
