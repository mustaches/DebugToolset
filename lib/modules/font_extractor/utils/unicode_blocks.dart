/// Unicode block definitions and character-set range helpers for the
/// font extractor module.
///
/// This file is pure Dart (no Flutter imports) so it can be unit tested
/// without a widget binding.
library;

/// Text direction of a Unicode block. RTL blocks (Arabic, Hebrew, ...)
/// are marked so the extractor can record direction metadata and the
/// preview can hint rendering order.
enum TextDir { ltr, rtl }

/// A named Unicode block with an inclusive code point range.
class UnicodeBlock {
  final String name;
  final int start;
  final int end;
  final TextDir direction;

  const UnicodeBlock(
    this.name,
    this.start,
    this.end, {
    this.direction = TextDir.ltr,
  });

  int get length => end - start + 1;
}

/// Common Unicode blocks offered as quick character-set choices.
const List<UnicodeBlock> kUnicodeBlocks = [
  UnicodeBlock('Basic Latin 基本拉丁字母', 0x0000, 0x007F),
  UnicodeBlock('Latin-1 Supplement 拉丁字母补充-1', 0x0080, 0x00FF),
  UnicodeBlock('Latin Extended-A 拉丁字母扩展-A', 0x0100, 0x017F),
  UnicodeBlock('Latin Extended-B 拉丁字母扩展-B', 0x0180, 0x024F),
  UnicodeBlock('IPA Extensions 国际音标扩展', 0x0250, 0x02AF),
  UnicodeBlock('Spacing Modifier Letters 占位修饰符号', 0x02B0, 0x02FF),
  UnicodeBlock('Combining Diacritical Marks 组合附加符号', 0x0300, 0x036F),
  UnicodeBlock('Greek and Coptic 希腊字母与科普特文', 0x0370, 0x03FF),
  UnicodeBlock('Cyrillic 西里尔字母', 0x0400, 0x04FF),
  UnicodeBlock('Cyrillic Supplement 西里尔字母补充', 0x0500, 0x052F),
  UnicodeBlock('Armenian 亚美尼亚字母', 0x0530, 0x058F),
  UnicodeBlock('Hebrew 希伯来字母', 0x0590, 0x05FF, direction: TextDir.rtl),
  UnicodeBlock('Arabic 阿拉伯字母', 0x0600, 0x06FF, direction: TextDir.rtl),
  UnicodeBlock('Syriac 叙利亚字母', 0x0700, 0x074F, direction: TextDir.rtl),
  UnicodeBlock('Arabic Supplement 阿拉伯字母补充', 0x0750, 0x077F, direction: TextDir.rtl),
  UnicodeBlock('Thaana 迪维希文/塔纳文', 0x0780, 0x07BF, direction: TextDir.rtl),
  UnicodeBlock('N\'Ko 西非书面文字', 0x07C0, 0x07FF, direction: TextDir.rtl),
  UnicodeBlock('Samaritan 撒玛利亚字母', 0x0800, 0x083F, direction: TextDir.rtl),
  UnicodeBlock('Mandaic 曼达安文字', 0x0840, 0x085F, direction: TextDir.rtl),
  UnicodeBlock('Arabic Extended-B 阿拉伯字母扩展-B', 0x0870, 0x089F, direction: TextDir.rtl),
  UnicodeBlock('Arabic Extended-A 阿拉伯字母扩展-A', 0x08A0, 0x08FF, direction: TextDir.rtl),
  UnicodeBlock('Devanagari 天城文', 0x0900, 0x097F),
  UnicodeBlock('Bengali 孟加拉文', 0x0980, 0x09FF),
  UnicodeBlock('Gurmukhi 旁遮普文/古木基文', 0x0A00, 0x0A7F),
  UnicodeBlock('Gujarati 古吉拉特文', 0x0A80, 0x0AFF),
  UnicodeBlock('Oriya 奥里亚文', 0x0B00, 0x0B7F),
  UnicodeBlock('Tamil 泰米尔文', 0x0B80, 0x0BFF),
  UnicodeBlock('Telugu 泰卢固文', 0x0C00, 0x0C7F),
  UnicodeBlock('Kannada 卡纳达文', 0x0C80, 0x0CFF),
  UnicodeBlock('Malayalam 马拉雅拉姆文', 0x0D00, 0x0D7F),
  UnicodeBlock('Sinhala 僧伽罗文', 0x0D80, 0x0DFF),
  UnicodeBlock('Thai 泰文', 0x0E00, 0x0E7F),
  UnicodeBlock('Lao 老挝文', 0x0E80, 0x0EFF),
  UnicodeBlock('Tibetan 藏文', 0x0F00, 0x0FFF),
  UnicodeBlock('Myanmar 缅甸文', 0x1000, 0x109F),
  UnicodeBlock('Georgian 格鲁吉亚字母', 0x10A0, 0x10FF),
  UnicodeBlock('Hangul Jamo 韩文字母', 0x1100, 0x11FF),
  UnicodeBlock('Ethiopic 埃塞俄比亚字母/吉兹文', 0x1200, 0x137F),
  UnicodeBlock('Ethiopic Supplement 埃塞俄比亚字母补充', 0x1380, 0x139F),
  UnicodeBlock('Cherokee 切罗基字母', 0x13A0, 0x13FF),
  UnicodeBlock('Unified Canadian Aboriginal Syllabics 加拿大土著音节文字', 0x1400, 0x167F),
  UnicodeBlock('Ogham 欧甘字母', 0x1680, 0x169F),
  UnicodeBlock('Runic 卢恩字母/如尼文', 0x16A0, 0x16FF),
  UnicodeBlock('Tagalog 塔加洛文', 0x1700, 0x171F),
  UnicodeBlock('Hanunoo 哈努诺文', 0x1720, 0x173F),
  UnicodeBlock('Buhid 布希德文', 0x1740, 0x175F),
  UnicodeBlock('Tagbanwa 塔格巴努亚文', 0x1760, 0x177F),
  UnicodeBlock('Khmer 柬埔寨文/高棉文', 0x1780, 0x17FF),
  UnicodeBlock('Mongolian 蒙古文', 0x1800, 0x18AF),
  UnicodeBlock('Unified Canadian Aboriginal Syllabics Extended 加拿大土著音节文字扩展', 0x18B0, 0x18FF),
  UnicodeBlock('Limbu 林布文', 0x1900, 0x194F),
  UnicodeBlock('Tai Le 傣仂文', 0x1950, 0x197F),
  UnicodeBlock('New Tai Lue 新傣仂文', 0x1980, 0x19DF),
  UnicodeBlock('Khmer Symbols 高棉文符号', 0x19E0, 0x19FF),
  UnicodeBlock('Buginese 布吉文', 0x1A00, 0x1A1F),
  UnicodeBlock('Tai Tham 兰纳文/老傣文', 0x1A20, 0x1AAF),
  UnicodeBlock('Combining Diacritical Marks Extended 组合附加符号扩展', 0x1AB0, 0x1AFF),
  UnicodeBlock('Balinese 巴厘文', 0x1B00, 0x1B7F),
  UnicodeBlock('Sundanese 巽他文', 0x1B80, 0x1BBF),
  UnicodeBlock('Batak 巴塔克文', 0x1BC0, 0x1BFF),
  UnicodeBlock('Lepcha 雷布查文', 0x1C00, 0x1C4F),
  UnicodeBlock('Ol Chiki 奥奇基文', 0x1C50, 0x1C7F),
  UnicodeBlock('Cyrillic Extended-C 西里尔字母扩展-C', 0x1C80, 0x1C8F),
  UnicodeBlock('Georgian Extended 格鲁吉亚字母扩展', 0x1C90, 0x1CBF),
  UnicodeBlock('Sundanese Supplement 巽他文补充', 0x1CC0, 0x1CCF),
  UnicodeBlock('Vedic Extensions 吠陀文扩展', 0x1CD0, 0x1CFF),
  UnicodeBlock('Phonetic Extensions 音标扩展', 0x1D00, 0x1D7F),
  UnicodeBlock('Phonetic Extensions Supplement 音标扩展补充', 0x1D80, 0x1DBF),
  UnicodeBlock('Combining Diacritical Marks Supplement 组合附加符号补充', 0x1DC0, 0x1DFF),
  UnicodeBlock('Latin Extended Additional 拉丁文扩展附加', 0x1E00, 0x1EFF),
  UnicodeBlock('Greek Extended 希腊字母扩展', 0x1F00, 0x1FFF),
  UnicodeBlock('General Punctuation 常用标点符号', 0x2000, 0x206F),
  UnicodeBlock('Superscripts and Subscripts 上标与下标', 0x2070, 0x209F),
  UnicodeBlock('Currency Symbols 货币符号', 0x20A0, 0x20CF),
  UnicodeBlock('Combining Diacritical Marks for Symbols 组合用符号附加标记', 0x20D0, 0x20FF),
  UnicodeBlock('Letterlike Symbols 字母式符号', 0x2100, 0x214F),
  UnicodeBlock('Number Forms 数字形式', 0x2150, 0x218F),
  UnicodeBlock('Arrows 箭头符号', 0x2190, 0x21FF),
  UnicodeBlock('Mathematical Operators 数学运算符', 0x2200, 0x22FF),
  UnicodeBlock('Miscellaneous Technical 杂项工业/技术符号', 0x2300, 0x23FF),
  UnicodeBlock('Control Pictures 控制符图形', 0x2400, 0x243F),
  UnicodeBlock('Optical Character Recognition 光学字符识别 (OCR)', 0x2440, 0x245F),
  UnicodeBlock('Enclosed Alphanumerics 带圈字母数字', 0x2460, 0x24FF),
  UnicodeBlock('Box Drawing 框线/制表符', 0x2500, 0x257F),
  UnicodeBlock('Block Elements 方块元素', 0x2580, 0x259F),
  UnicodeBlock('Geometric Shapes 几何图形', 0x25A0, 0x25FF),
  UnicodeBlock('Miscellaneous Symbols 杂项符号', 0x2600, 0x26FF),
  UnicodeBlock('Dingbats 装饰符号/丁伯符号', 0x2700, 0x27BF),
  UnicodeBlock('Miscellaneous Mathematical Symbols-A 杂项数学符号-A', 0x27C0, 0x27EF),
  UnicodeBlock('Supplemental Arrows-A 补充箭头-A', 0x27F0, 0x27FF),
  UnicodeBlock('Braille Patterns 盲文点字图案', 0x2800, 0x28FF),
  UnicodeBlock('Supplemental Arrows-B 补充箭头-B', 0x2900, 0x297F),
  UnicodeBlock('Miscellaneous Mathematical Symbols-B 杂项数学符号-B', 0x2980, 0x29FF),
  UnicodeBlock('Supplemental Mathematical Operators 补充数学运算符', 0x2A00, 0x2AFF),
  UnicodeBlock('Miscellaneous Symbols and Arrows 杂项符号和箭头', 0x2B00, 0x2BFF),
  UnicodeBlock('Glagolitic 格拉哥里字母', 0x2C00, 0x2C5F),
  UnicodeBlock('Latin Extended-C 拉丁字母扩展-C', 0x2C60, 0x2C7F),
  UnicodeBlock('Coptic 科普特文', 0x2C80, 0x2CFF),
  UnicodeBlock('Georgian Supplement 格鲁吉亚字母补充', 0x2D00, 0x2D2F),
  UnicodeBlock('Tifinagh 提非纳字母/柏柏尔文', 0x2D30, 0x2D7F),
  UnicodeBlock('Ethiopic Extended 埃塞俄比亚字母扩展', 0x2D80, 0x2DDF),
  UnicodeBlock('Cyrillic Extended-A 西里尔字母扩展-A', 0x2DE0, 0x2DFF),
  UnicodeBlock('Supplemental Punctuation 补充标点', 0x2E00, 0x2E7F),
  UnicodeBlock('CJK Radicals Supplement CJK部首补充', 0x2E80, 0x2EFF),
  UnicodeBlock('Kangxi Radicals 康熙部首', 0x2F00, 0x2FDF),
  UnicodeBlock('Ideographic Description Characters 汉字结构描述字符', 0x2FF0, 0x2FFF),
  UnicodeBlock('CJK Symbols and Punctuation CJK符号和标点', 0x3000, 0x303F),
  UnicodeBlock('Hiragana 日文平假名', 0x3040, 0x309F),
  UnicodeBlock('Katakana 日文片假名', 0x30A0, 0x30FF),
  UnicodeBlock('Bopomofo 汉语注音符号', 0x3100, 0x312F),
  UnicodeBlock('Hangul Compatibility Jamo 韩文兼容字母', 0x3130, 0x318F),
  UnicodeBlock('Kanbun 汉文训读符号', 0x3190, 0x319F),
  UnicodeBlock('Bopomofo Extended 汉语注音符号扩展', 0x31A0, 0x31BF),
  UnicodeBlock('CJK Strokes CJK笔画', 0x31C0, 0x31EF),
  UnicodeBlock('Katakana Phonetic Extensions 片假名音标扩展', 0x31F0, 0x31FF),
  UnicodeBlock('Enclosed CJK Letters and Months 带圈CJK字符和月份', 0x3200, 0x32FF),
  UnicodeBlock('CJK Compatibility CJK兼容字符', 0x3300, 0x33FF),
  UnicodeBlock('CJK Unified Ideographs Extension A 中日韩统一表意文字扩展-A', 0x3400, 0x4DBF),
  UnicodeBlock('Yijing Hexagram Symbols 易经六十四卦符号', 0x4DC0, 0x4DFF),
  UnicodeBlock('CJK Unified Ideographs 中日韩统一表意文字 (基本区)', 0x4E00, 0x9FFF),
  UnicodeBlock('Yi Syllables 彝文音节', 0xA000, 0xA48F),
  UnicodeBlock('Yi Radicals 彝文部首', 0xA490, 0xA4CF),
  UnicodeBlock('Lisu 傈僳文', 0xA4D0, 0xA4FF),
  UnicodeBlock('Vai 瓦伊语音节文字', 0xA500, 0xA63F),
  UnicodeBlock('Cyrillic Extended-B 西里尔字母扩展-B', 0xA640, 0xA69F),
  UnicodeBlock('Bamum 巴姆穆文字', 0xA6A0, 0xA6FF),
  UnicodeBlock('Modifier Tone Letters 声调修饰字母', 0xA700, 0xA71F),
  UnicodeBlock('Latin Extended-D 拉丁字母扩展-D', 0xA720, 0xA7FF),
  UnicodeBlock('Syloti Nagri 斯里兰卡/锡尔赫特文', 0xA800, 0xA82F),
  UnicodeBlock('Common Indic Number Forms 印度数字形式', 0xA830, 0xA83F),
  UnicodeBlock('Phags-pa 八思巴文', 0xA840, 0xA87F),
  UnicodeBlock('Saurashtra 索拉什特拉文', 0xA880, 0xA8DF),
  UnicodeBlock('Devanagari Extended 天城文扩展', 0xA8E0, 0xA8FF),
  UnicodeBlock('Kayah Li 克耶文', 0xA900, 0xA92F),
  UnicodeBlock('Rejang 勒江文', 0xA930, 0xA95F),
  UnicodeBlock('Hangul Jamo Extended-A 韩文字母扩展-A', 0xA960, 0xA97F),
  UnicodeBlock('Javanese 爪哇文', 0xA980, 0xA9DF),
  UnicodeBlock('Myanmar Extended-B 缅甸文扩展-B', 0xA9E0, 0xA9FF),
  UnicodeBlock('Cham 占文', 0xAA00, 0xAA5F),
  UnicodeBlock('Myanmar Extended-A 缅甸文扩展-A', 0xAA60, 0xAA7F),
  UnicodeBlock('Tai Viet 新太文/傣担文', 0xAA80, 0xAADF),
  UnicodeBlock('Meetei Mayek Extensions 曼尼普尔文扩展', 0xAAE0, 0xAAFF),
  UnicodeBlock('Ethiopic Extended-A 埃塞俄比亚字母扩展-A', 0xAB00, 0xAB2F),
  UnicodeBlock('Latin Extended-E 拉丁字母扩展-E', 0xAB30, 0xAB6F),
  UnicodeBlock('Cherokee Supplement 切罗基字母补充', 0xAB70, 0xABBF),
  UnicodeBlock('Meetei Mayek 曼尼普尔文', 0xABC0, 0xABFF),
  UnicodeBlock('Hangul Syllables 韩文音节', 0xAC00, 0xD7AF),
  UnicodeBlock('Hangul Jamo Extended-B 韩文字母扩展-B', 0xD7B0, 0xD7FF),
  UnicodeBlock('Private Use Area (BMP PUA) 用户自定义区', 0xE000, 0xF8FF),
  UnicodeBlock('CJK Compatibility Ideographs CJK兼容汉字', 0xF900, 0xFAFF),
  UnicodeBlock('Alphabetic Presentation Forms 字母表现形式', 0xFB00, 0xFB4F),
  UnicodeBlock('Arabic Presentation Forms-A 阿拉伯文表现形式-A', 0xFB50, 0xFDFF, direction: TextDir.rtl),
  UnicodeBlock('Variation Selectors 字形变体选择器', 0xFE00, 0xFE0F),
  UnicodeBlock('Vertical Forms 竖排形式', 0xFE10, 0xFE1F),
  UnicodeBlock('Combining Half Marks 组合半标记', 0xFE20, 0xFE2F),
  UnicodeBlock('CJK Compatibility Forms CJK兼容形式', 0xFE30, 0xFE4F),
  UnicodeBlock('Small Form Variants 小写形式变体', 0xFE50, 0xFE6F),
  UnicodeBlock('Arabic Presentation Forms-B 阿拉伯文表现形式-B', 0xFE70, 0xFEFF, direction: TextDir.rtl),
  UnicodeBlock('Halfwidth and Fullwidth Forms 半角与全角字符', 0xFF00, 0xFFEF),
  UnicodeBlock('Specials 特殊字符区', 0xFFF0, 0xFFFF),
  UnicodeBlock('Linear B Syllabary 线形文字B音节文字', 0x10000, 0x1007F),
  UnicodeBlock('Linear B Ideograms 线形文字B表意文字', 0x10080, 0x100FF),
  UnicodeBlock('Aegean Numbers 爱琴海数字', 0x10100, 0x1013F),
  UnicodeBlock('Ancient Greek Numbers 古希腊数字', 0x10140, 0x1018F),
  UnicodeBlock('Ancient Symbols 古代符号', 0x10190, 0x101CF),
  UnicodeBlock('Phaistos Disc 斐斯托斯圆盘文字', 0x101D0, 0x101FF),
  UnicodeBlock('Lycian 利西亚字母', 0x10280, 0x1029F),
  UnicodeBlock('Carian 卡里亚字母', 0x102A0, 0x102DF),
  UnicodeBlock('Old Italic 古意大利字母', 0x10300, 0x1032F),
  UnicodeBlock('Gothic 哥特字母', 0x10330, 0x1034F),
  UnicodeBlock('Ugaritic 乌加里特楔形字母', 0x10380, 0x1039F),
  UnicodeBlock('Old Persian 古波斯楔形文字', 0x103A0, 0x103DF),
  UnicodeBlock('Deseret 德瑟雷特字母', 0x10400, 0x1044F),
  UnicodeBlock('Shavian 萧伯纳字母', 0x10450, 0x1047F),
  UnicodeBlock('Osmanya 奥斯曼亚文', 0x10480, 0x104AF),
  UnicodeBlock('Osage 奥塞奇字母', 0x104B0, 0x104FF),
  UnicodeBlock('Elbasan 埃尔巴桑字母', 0x10500, 0x1052F),
  UnicodeBlock('Caucasian Albanian 高加索阿尔巴尼亚文', 0x10530, 0x1056F),
  UnicodeBlock('Linear A 线形文字A', 0x10600, 0x1077F),
  UnicodeBlock('Latin Extended-F 拉丁字母扩展-F', 0x10780, 0x107BF),
  UnicodeBlock('Palmyrene 帕尔米拉字母', 0x10840, 0x1085F, direction: TextDir.rtl),
  UnicodeBlock('Nabataean 纳巴泰字母', 0x10880, 0x108AF, direction: TextDir.rtl),
  UnicodeBlock('Phoenician 腓尼基字母', 0x10900, 0x1091F, direction: TextDir.rtl),
  UnicodeBlock('Lydian 吕底亚字母', 0x10920, 0x1093F, direction: TextDir.rtl),
  UnicodeBlock('Meroitic Hieroglyphs 麦罗埃圣书体', 0x10980, 0x1099F),
  UnicodeBlock('Meroitic Cursive 麦罗埃草书', 0x109A0, 0x109FF),
  UnicodeBlock('Kharoshthi 佉卢文', 0x10A00, 0x10A5F, direction: TextDir.rtl),
  UnicodeBlock('Old South Arabian 古南阿拉伯字母', 0x10A60, 0x10A7F, direction: TextDir.rtl),
  UnicodeBlock('Old North Arabian 古北阿拉伯字母', 0x10A80, 0x10A9F, direction: TextDir.rtl),
  UnicodeBlock('Manichaean 摩尼教字母', 0x10AC0, 0x10AFF, direction: TextDir.rtl),
  UnicodeBlock('Avestan 阿维斯陀字母', 0x10B00, 0x10B3F, direction: TextDir.rtl),
  UnicodeBlock('Parthian 帕提亚字母', 0x10B40, 0x10B5F, direction: TextDir.rtl),
  UnicodeBlock('Inscriptional Pahlavi 碑铭巴列维文', 0x10B60, 0x10B7F, direction: TextDir.rtl),
  UnicodeBlock('Psalter Pahlavi 诗篇巴列维文', 0x10B80, 0x10BAF, direction: TextDir.rtl),
  UnicodeBlock('Old Turkic 古突厥文/突厥如尼文', 0x10C00, 0x10C4F, direction: TextDir.rtl),
  UnicodeBlock('Old Hungarian 古匈牙利字母', 0x10C80, 0x10CFF, direction: TextDir.rtl),
  UnicodeBlock('Hanifi Rohingya 罗兴亚韩纳菲文', 0x10D00, 0x10D3F, direction: TextDir.rtl),
  UnicodeBlock('Old Sogdian 古粟特字母', 0x10F00, 0x10F2F, direction: TextDir.rtl),
  UnicodeBlock('Sogdian 粟特字母', 0x10F30, 0x10F6F, direction: TextDir.rtl),
  UnicodeBlock('Brahmi 婆罗米文', 0x11000, 0x1107F),
  UnicodeBlock('Kaithi 凯提文', 0x11080, 0x110CF),
  UnicodeBlock('Sora Sompeng 索拉僧平文', 0x110D0, 0x110FF),
  UnicodeBlock('Chakma 查克马文', 0x11100, 0x1114F),
  UnicodeBlock('Mahajani 马哈佳尼文', 0x11150, 0x1117F),
  UnicodeBlock('Sharada 沙拉达文', 0x11180, 0x111DF),
  UnicodeBlock('Khojki 霍吉基文', 0x11200, 0x1124F),
  UnicodeBlock('Multani 穆尔坦文', 0x11280, 0x112AF),
  UnicodeBlock('Khudawadi 库达瓦迪文', 0x112B0, 0x112FF),
  UnicodeBlock('Grantha 格兰他文', 0x11300, 0x1137F),
  UnicodeBlock('Newa 纽瓦文', 0x11400, 0x1147F),
  UnicodeBlock('Tirhuta 提尔胡塔文', 0x11480, 0x114DF),
  UnicodeBlock('Siddham 悉昙文', 0x11580, 0x115FF),
  UnicodeBlock('Modi 莫迪文', 0x11600, 0x1165F),
  UnicodeBlock('Takri 塔克里文', 0x11680, 0x116CF),
  UnicodeBlock('Ahom 阿洪姆文', 0x11700, 0x1174F),
  UnicodeBlock('Dogra 多格拉文', 0x11800, 0x1184F),
  UnicodeBlock('Dives Akuru 迪维希阿库鲁文', 0x11900, 0x1195F),
  UnicodeBlock('Nandinagari 南迪纳加里文', 0x119A0, 0x119FF),
  UnicodeBlock('Zanabazar Square 扎那巴扎尔方形字母', 0x11A00, 0x11A4F),
  UnicodeBlock('Soyombo 索永布文', 0x11A50, 0x11AAF),
  UnicodeBlock('Pau Cin Hau 鲍钦豪文', 0x11AC0, 0x11AFF),
  UnicodeBlock('Bhaiksuki 梵许基文', 0x11C00, 0x11C6F),
  UnicodeBlock('Marchen 玛尔辰文', 0x11C70, 0x11CBF),
  UnicodeBlock('Masaram Gondi 玛萨朗贡德文', 0x11D00, 0x11D5F),
  UnicodeBlock('Gunjala Gondi 贡加拉贡德文', 0x11D60, 0x11DAF),
  UnicodeBlock('Makasar 望加锡文', 0x11EE0, 0x11EFF),
  UnicodeBlock('Cuneiform 楔形文字', 0x12000, 0x123FF),
  UnicodeBlock('Cuneiform Numbers and Punctuation 楔形文字数字与标点', 0x12400, 0x1247F),
  UnicodeBlock('Early Dynastic Cuneiform 早期王朝楔形文字', 0x12480, 0x1254F),
  UnicodeBlock('Egyptian Hieroglyphs 埃及圣书体', 0x13000, 0x1342F),
  UnicodeBlock('Egyptian Hieroglyph Format Controls 埃及圣书体格式控制符', 0x13430, 0x1345F),
  UnicodeBlock('Anatolian Hieroglyphs 阿纳托利亚象形文字', 0x14400, 0x1467F),
  UnicodeBlock('Bamum Supplement 巴姆穆文字补充', 0x16800, 0x16A3F),
  UnicodeBlock('Mro 姆罗文', 0x16A40, 0x16A6F),
  UnicodeBlock('Bassa Vah 巴萨文', 0x16AD0, 0x16AFF),
  UnicodeBlock('Pahawh Hmong 柏格理苗文/巴哈苗文', 0x16B00, 0x16B8F),
  UnicodeBlock('Medefaidrin 麦德法伊德林文', 0x16E40, 0x16E9F),
  UnicodeBlock('Miao 苗文/柏格理苗文', 0x16F00, 0x16F9F),
  UnicodeBlock('Tangut 西夏文', 0x17000, 0x187F0),
  UnicodeBlock('Tangut Components 西夏文字根', 0x18800, 0x18AF0),
  UnicodeBlock('Khitan Small Script 契丹小字', 0x18B00, 0x18CD0),
  UnicodeBlock('Tangut Supplement 西夏文补充', 0x18D00, 0x18D0F),
  UnicodeBlock('Nushu 女书', 0x1B170, 0x1B2FB),
  UnicodeBlock('Duployan 杜普雷速记文字', 0x1BC00, 0x1BC9F),
  UnicodeBlock('Shorthand Format Controls 速记格式控制符', 0x1BCA0, 0x1BCA3),
  UnicodeBlock('Musical Symbols 音乐符号', 0x1D000, 0x1D0FF),
  UnicodeBlock('Byzantine Musical Symbols 拜占庭音乐符号', 0x1D100, 0x1D1FF),
  UnicodeBlock('Ancient Greek Musical Notation 古希腊音乐记号', 0x1D200, 0x1D24F),
  UnicodeBlock('Mayan Numerals 玛雅数字', 0x1D2E0, 0x1D2FF),
  UnicodeBlock('Tai Xuan Jing Symbols 太玄经符号', 0x1D300, 0x1D35F),
  UnicodeBlock('Counting Rod Numerals 算筹数字', 0x1D360, 0x1D37F),
  UnicodeBlock('Mathematical Alphanumeric Symbols 数学字母数字符号', 0x1D400, 0x1D7FF),
  UnicodeBlock('Sutton SignWriting 萨顿手语书写符号', 0x1D800, 0x1DAAF),
  UnicodeBlock('Glagolitic Supplement 格拉哥里字母补充', 0x1E000, 0x1E02F),
  UnicodeBlock('Nyiakeng Puachue Hmong 捏啃普阿曲苗文', 0x1E100, 0x1E14F),
  UnicodeBlock('Wancho 旺秋字母', 0x1E2C0, 0x1E2FF),
  UnicodeBlock('Mende Kikakui 门德基卡库文', 0x1E800, 0x1E8DF, direction: TextDir.rtl),
  UnicodeBlock('Adlam 阿德拉姆字母', 0x1E900, 0x1E95F, direction: TextDir.rtl),
  UnicodeBlock('Indic Siyaq Numbers 印度西亚克数字', 0x1EC70, 0x1ECBF, direction: TextDir.rtl),
  UnicodeBlock('Ottoman Siyaq Numbers 奥斯曼西亚克数字', 0x1ED00, 0x1ED4F, direction: TextDir.rtl),
  UnicodeBlock('Arabic Mathematical Alphabetic Symbols 阿拉伯数学字母符号', 0x1EE00, 0x1EEFF, direction: TextDir.rtl),
  UnicodeBlock('Mahjong Tiles 麻将牌符号', 0x1F000, 0x1F02F),
  UnicodeBlock('Domino Tiles 多米诺骨牌', 0x1F030, 0x1F09F),
  UnicodeBlock('Playing Cards 扑克牌图形', 0x1F0A0, 0x1F0FF),
  UnicodeBlock('Enclosed Alphanumeric Supplement 带圈字母数字补充', 0x1F100, 0x1F1FF),
  UnicodeBlock('Enclosed Ideographic Supplement 带圈CJK字符补充', 0x1F200, 0x1F2FF),
  UnicodeBlock('Miscellaneous Symbols and Pictographs 杂项表情与象形图', 0x1F300, 0x1F5FF),
  UnicodeBlock('Emoticons (Emoji) 表情符号', 0x1F600, 0x1F64F),
  UnicodeBlock('Ornamental Dingbats 装饰性丁伯符号', 0x1F650, 0x1F67F),
  UnicodeBlock('Transport and Map Symbols 交通和地图符号', 0x1F680, 0x1F6FF),
  UnicodeBlock('Alchemical Symbols 炼金术符号', 0x1F700, 0x1F77F),
  UnicodeBlock('Geometric Shapes Extended 扩展几何图形', 0x1F780, 0x1F7FF),
  UnicodeBlock('Supplemental Arrows-C 补充箭头-C', 0x1F800, 0x1F8FF),
  UnicodeBlock('Supplemental Symbols and Pictographs 补充符号和象形图', 0x1F900, 0x1F9FF),
  UnicodeBlock('Chess Symbols 象棋与棋类符号', 0x1FA00, 0x1FA6F),
  UnicodeBlock('Symbols and Pictographs Extended-A 扩展符号与象形图-A', 0x1FA70, 0x1FAFF),
  UnicodeBlock('Symbols for Legacy Computing 复古计算机符号', 0x1FB00, 0x1FBFF),
  UnicodeBlock('CJK Unified Ideographs Extension B 中日韩统一表意文字扩展-B', 0x20000, 0x2A6DF),
  UnicodeBlock('CJK Unified Ideographs Extension C 中日韩统一表意文字扩展-C', 0x2A700, 0x2B73F),
  UnicodeBlock('CJK Unified Ideographs Extension D 中日韩统一表意文字扩展-D', 0x2B740, 0x2B81F),
  UnicodeBlock('CJK Unified Ideographs Extension E 中日韩统一表意文字扩展-E', 0x2B820, 0x2CEAF),
  UnicodeBlock('CJK Unified Ideographs Extension F 中日韩统一表意文字扩展-F', 0x2CEB0, 0x2EBE0),
  UnicodeBlock('CJK Unified Ideographs Extension I 中日韩统一表意文字扩展-I', 0x2EBF0, 0x2EE5F),
  UnicodeBlock('CJK Compatibility Ideographs Supplement CJK兼容汉字补充', 0x2F800, 0x2FA1D),
  UnicodeBlock('CJK Unified Ideographs Extension G 中日韩统一表意文字扩展-G', 0x30000, 0x3134F),
  UnicodeBlock('CJK Unified Ideographs Extension H 中日韩统一表意文字扩展-H', 0x31350, 0x323AF),
  UnicodeBlock('Tags 标签字符区', 0xE0000, 0xE007F),
  UnicodeBlock('Variation Selectors Supplement 变体选择器补充', 0xE0100, 0xE01EF),
  UnicodeBlock('Supplementary Private Use Area-A 补充专用区-A (Plane 15 PUA)', 0xF0000, 0xFFFFF),
  UnicodeBlock('Supplementary Private Use Area-B 补充专用区-B (Plane 16 PUA)', 0x100000, 0x10FFFF),
];

/// Parses a free-form range input such as
/// `0x20-0x7E, 0x4E00-0x9FFF, U+0600, 32-126`
/// into a list of inclusive (start, end) pairs.
///
/// Throws [FormatException] with a human-readable message on bad input.
List<({int start, int end})> parseRangeInput(String input) {
  final result = <({int start, int end})>[];
  final parts = input.split(RegExp(r'[,;，；\s]+'));
  for (final raw in parts) {
    final part = raw.trim();
    if (part.isEmpty) continue;

    // Split a single range "A-B" but tolerate a lone value "A".
    final dash = part.indexOf('-');
    final startStr = dash == -1 ? part : part.substring(0, dash);
    final endStr = dash == -1 ? part : part.substring(dash + 1);

    final start = _parseCodePoint(startStr);
    final end = _parseCodePoint(endStr);
    if (start == null || end == null) {
      throw FormatException('无法解析的码点: "$part"');
    }
    if (start > end) {
      throw FormatException('范围起点大于终点: "$part"');
    }
    if (end > 0x10FFFF) {
      throw FormatException('码点超出 Unicode 范围: "$part"');
    }
    result.add((start: start, end: end));
  }
  return result;
}

int? _parseCodePoint(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  if (t.toUpperCase().startsWith('U+')) {
    t = t.substring(2);
    return int.tryParse(t, radix: 16);
  }
  if (t.toLowerCase().startsWith('0x')) {
    return int.tryParse(t.substring(2), radix: 16);
  }
  // Plain hex (contains A-F) or plain decimal.
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(t) &&
      RegExp(r'[a-fA-F]').hasMatch(t)) {
    return int.tryParse(t, radix: 16);
  }
  return int.tryParse(t);
}

/// Expands block selections and custom ranges into a sorted, de-duplicated
/// list of code points.
///
/// [blocks] are quick-pick blocks; [customRanges] are inclusive ranges as
/// produced by [parseRangeInput].
List<int> expandToCodePoints({
  Iterable<UnicodeBlock> blocks = const [],
  Iterable<({int start, int end})> customRanges = const [],
}) {
  final set = <int>{};
  for (final b in blocks) {
    for (int cp = b.start; cp <= b.end; cp++) {
      set.add(cp);
    }
  }
  for (final r in customRanges) {
    for (int cp = r.start; cp <= r.end; cp++) {
      set.add(cp);
    }
  }
  final list = set.toList()..sort();
  return list;
}

/// Formats a Unicode code point (supporting 16-bit BMP and up to 20-bit Plane 1-16)
/// as a standard hexadecimal string (e.g. `U+0041`, `U+1B170`, `U+10FFFF`).
String formatCodePoint(int codePoint, {bool includePrefix = true}) {
  final hex = codePoint.toRadixString(16).toUpperCase();
  final padded = codePoint > 0xFFFFF
      ? hex.padLeft(6, '0')
      : (codePoint > 0xFFFF ? hex.padLeft(5, '0') : hex.padLeft(4, '0'));
  return includePrefix ? 'U+$padded' : padded;
}
