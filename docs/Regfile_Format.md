# Regfile 寄存器文件格式规范

`.Regfile` 是基于 JSON 语法的配置文件，用于向 I2C 协议分析器（Oscilloscope 等应用）提供目标设备的寄存器定义、说明、访问权限以及字段解码映射。

挂载 `.Regfile` 文件后，分析器可直接在图形界面中对截获的读写报文（例如 `0x5E` 设备下地址为 `0x00` 的写入操作）进行位（Bit）级别的解析和中文/英文翻译，免去了工程师一边查波形一边对照芯片数据手册的繁琐工作。

---

## 1. 根级别结构 (Root Structure)

每个 `.Regfile` 文件的顶层必须是一个合法的 JSON 对象，包含以下基本字段：

```json
{
  "name": "SN65DP159",
  "addresses": ["0x5E", "0x5F"],
  "hasSubaddress": false,
  "addressMap": {
    "0x5C": "A1=1, A0=0",
    "0x5B": "A1=1, A0=1"
  },
  "registers": {
    ...
  }
}
```

| 字段名 | 类型 | 说明 |
| --- | --- | --- |
| `name` | String (必填) | 设备名称或型号名称，用于在 UI 的挂载列表和标题栏中展示。 |
| `addresses` | Array[String/Int] (选填) | 该芯片支持的 I2C 地址列表（十六进制字符串或整数）。当总线上出现匹配的地址时，系统可能会自动将此文件作为匹配候选项。 |
| `addressMap` | Object (选填) | 定义 I2C 地址到**外围硬件配置引脚**的映射。在波形解析时，不仅能匹配设备地址，还能在 UI 标题上提示当前的硬件接线方式（如 `[Pin Config: A1=1, A0=0]`）。它与 `addresses` 选其一即可。 |
| `hasSubaddress` | Boolean (选填) | 芯片是否使用寄存器子地址（默认为 `true`）。部分 I2C 芯片（如 Switch/IO 扩展芯片，如 TCA9548A）写操作没有子地址阶段，第一个 Byte 即为数据。若设为 `false`，界面将会把所有数据映射到 `0x00` 地址。 |
| `registers` | Object (必填) | 寄存器映射字典。其键（Key）为寄存器的子地址，其值（Value）为寄存器的详细定义。 |

---

## 2. 寄存器定义 (Register Definition)

`registers` 字典中的每一个 Key 应该是一个表示十六进制的字符串（如 `"0x00"`, `"0x1A"`, `"0xFF"`），Value 为该寄存器的属性对象。

```json
"0x20": {
  "name": "AUX Output Control",
  "access": "R/W",
  "description": "AUX Output Control Register. Handles slew rate and swing.",
  "fields": [
    ...
  ]
}
```

| 字段名 | 类型 | 说明 |
| --- | --- | --- |
| `name` | String (必填) | 寄存器的名称或简写（如 `DEVICE_ID`）。 |
| `access` | String (选填) | 寄存器的整体访问权限。常用的如 `R` (Read Only), `W` (Write Only), `R/W` (Read/Write), `RU` 等。 |
| `description` | String (选填) | 寄存器的完整功能说明（Description）。将在解析窗口中长文本展示，可以直接从 Datasheet 摘抄。 |
| `fields` | Array[Object] (必填) | 包含该寄存器所有位字段（Bit-field）定义的数组。 |

---

## 3. 位字段定义 (Field Definition)

`fields` 数组规定了此寄存器在一个 Byte（8 bit）中不同位段的具体含义。支持为每个字段单独编写映射表。

```json
{
  "name": "AUX_SWING",
  "startBit": 0,
  "endBit": 2,
  "access": "RW",
  "description": "Swing Control for AUX Output",
  "valueMap": {
    "0": "270mV",
    "1": "355mV",
    "2": "450mV",
    "7": "Not allowed"
  }
}
```

| 字段名 | 类型 | 说明 |
| --- | --- | --- |
| `name` | String (必填) | 位段的缩写或名字（如 `AUX_SWING`）。 |
| `startBit` | Int (必填) | 位段的起始位（0~7）。如果是单比特字段，则 `startBit` 和 `endBit` 相同。 |
| `endBit` | Int (必填) | 位段的结束位（0~7）。要求 `endBit >= startBit`。 |
| `access` | String (选填) | 该位段的单独权限（如只读、读写、读后清零等）。 |
| `description` | String (选填) | 该位段的详细解释。 |
| `valueMap` | Object (选填) | **字段值映射表**。键（Key）必须是十进制数字的字符串，值（Value）是对应的释义。例如读取该位段的结果为 `0` 时，将在界面上翻译成 `"270mV"`。如果没有 `valueMap`，界面将只显示提取的二进制数据。 |

---

## 4. 界面解析效果

编写良好的 `.Regfile` 可以在解析时呈现如下 Verilog 风格及释义排版：

**Device: SN65DP159 (0x5E) [Pin Config: A1=0, A0=0] - Write**
Reg 0x20
**AUX Output Control**
Access: R/W
AUX Output Control Register.

`0x05` (写入的原始值)
- `Bit[3]` `1'b0` `AUX_TX_SR` (AUX_TX_SR Slew Rate Control...)
- `Bit[2:0]` `3'b101` `710mV` (AUX_SWING; Swing Control...)

## 5. 编写建议

1. **保留地址（Reserved）**：某些未指定的地址可能会被用作伪操作或页切换寄存器。如果 Datasheet 没有定义某个地址，建议将它们统一定义为 `Reserved` 或直接标明类似 `"Page Index Select"` 这样在 TI 芯片中常见的特定操作，防止在总线抓包时被识别为 `"Unknown"` 报错。
2. **Key 格式规范**：虽然解析器内部有容错处理，但是推荐所有的十六进制寄存器地址（Key）和映射表键都加上双引号并保证字符串规范，如 `"0x00"` 或 `"0x0C"`。
