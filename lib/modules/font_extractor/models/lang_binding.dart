import '../utils/unicode_blocks.dart';

/// Represents a national language or character region bound to a specific font file.
class LangBinding {
  /// Unique identifier (e.g. 'en_us', 'zh_cn', 'ru_ru', 'uk_ua').
  final String id;

  /// Language / Script display name (e.g. '简体中文 (CJK)', '藏语 (藏文)', '维吾尔语 (老维文)').
  final String name;

  /// Country flag emoji for visual recognition (e.g. '🇨🇳', '🇯🇵', '🇰🇷').
  final String flag;

  /// Continent category tag (e.g. '亚洲', '欧洲', '非洲', '美洲', '大洋洲', '符号与UI图形').
  final String continentTag;

  /// Geographic region category tag (e.g. '东亚', '东南亚', '南亚', '中亚', '西亚').
  final String regionTag;

  /// Country or territorial region tag (e.g. '中国', '日本', '韩国/朝鲜', '蒙古', '越南', '印度', '沙特').
  final String countryTag;

  /// Writing-system (charset) tag inside the region (e.g. '汉字', '藏文', '假名', '谚文', '拉丁文', '阿拉伯文').
  final String scriptTag;

  /// List of Unicode blocks associated with this national language.
  final List<UnicodeBlock> blocks;

  /// Sample text rendered with the candidate font in font picker preview.
  final String? sample;

  /// Path to the bound font file (null if not yet bound).
  String? fontPath;

  /// Localized family name of the bound font (cached for display).
  String? fontDisplayName;

  /// Original preset order index.
  final int originalIndex;

  /// Sequential order in which this language was bound (1, 2, 3...).
  int? boundOrder;

  LangBinding({
    required this.id,
    required this.name,
    required this.flag,
    String? continentTag,
    required this.regionTag,
    required this.countryTag,
    required this.scriptTag,
    required this.blocks,
    this.sample,
    this.originalIndex = 0,
    this.fontPath,
    this.fontDisplayName,
    this.boundOrder,
  }) : continentTag = (continentTag != null && continentTag.isNotEmpty)
            ? continentTag
            : deriveContinent(regionTag);

  /// Sample preview text for this language / script.
  String get sampleText {
    if (sample != null && sample!.isNotEmpty) return sample!;
    if (scriptTag.contains('假名')) return 'あいうえお アイウエオ 日本語';
    if (scriptTag.contains('谚文')) return '한글 테스트 한국어';
    if (scriptTag.contains('汉字')) return '中文字体演示，《红楼梦》，简体【】';
    if (scriptTag.contains('藏文')) return 'ཨོཾ་མ་ཎི་པདྨེ་ཧཱུྃ';
    if (scriptTag.contains('阿拉伯文')) return 'مرحبا بالعالم العربية';
    if (scriptTag.contains('彝文')) return 'ꆈꌠꁱꂷꉙꌠꅔꇓꇁꍏ';
    if (scriptTag.contains('女书')) return '𛅰𛅱𛅲𛅳𛅴';
    if (scriptTag.contains('傣文')) return 'ᥖᥭᥰᥖᥬᥳᥑ᥹ᥰ';
    if (scriptTag.contains('蒙古文')) return 'ᠰᠠᠢᠢᠨ ᠪᠠᠢᠢᠨ᠎ᠠ ᠤᠤ';
    if (scriptTag.contains('泰文')) return 'สวัสดีชาวโลก ภาษาไทย';
    if (scriptTag.contains('缅甸文')) return 'မင်္ဂလာပါကမ္ဘာလောက';
    if (scriptTag.contains('高棉文')) return 'ជំរាបសួរ​ពិភពលោក';
    if (scriptTag.contains('老挝文')) return 'ສະບາຍດີຊາວໂລກ';
    if (scriptTag.contains('天城文')) return 'नमस्ते दुनिया हिन्दी';
    if (scriptTag.contains('孟加拉文')) return 'ওহে বিশ্ব বাংলা';
    if (scriptTag.contains('泰米尔文')) return 'வணக்கம் உலகம் தமிழ்';
    if (scriptTag.contains('泰卢固文')) return 'నమస్తే ప్రపంచం తెలుగు';
    if (scriptTag.contains('卡纳达文')) return 'നമസ്കാരം';
    if (scriptTag.contains('马拉雅拉姆文')) return 'നമസ്കാരം മലയാളം';
    if (scriptTag.contains('古木基文')) return 'ਸਤਿ ਸ਼੍ਰੀ అਕਾਲ';
    if (scriptTag.contains('僧伽罗文')) return 'සිංහල';
    if (scriptTag.contains('塔纳文')) return 'އައްސަލާމް އަލައިކުމް';
    if (scriptTag.contains('希伯来文')) return 'שלום עולם עברית';
    if (scriptTag.contains('希腊文')) return 'Ξεσκεπάζω τὴν ψυχοφθόρα βδελυγμία';
    if (scriptTag.contains('西里尔文')) return 'Привет мир Русский язык';
    if (scriptTag.contains('亚美尼亚文')) return 'Բարև աշխայհ';
    if (scriptTag.contains('格鲁吉亚文')) return 'გამարජობა მსოფლიო';
    if (scriptTag.contains('吉兹文')) return 'ሰላም ልዑል';
    if (scriptTag.contains('切罗基文')) return 'ᏣᎳᎩ ᎦᏬᏂᎯᏍᏗ';
    if (scriptTag.contains('原住民音节')) return 'ᐊᓂᔥᓈᐯᒧᐎᓐ';
    if (scriptTag.contains('瓦伊文')) return 'ꕚꕌꕩ';
    if (scriptTag.contains('提非纳文')) return 'ⵜⵉⴼⵉⵏⴰⵖ';
    if (scriptTag.contains('奥斯曼亚文')) return '𐒋𐒘𐒈𐒑𐒛𐒒𐒕𐒖';
    if (scriptTag.contains('符号图形')) return '0123456789 \$ € ¥ £ ─│┌┐ █▌▐▀▄';
    return 'The quick brown fox jumps over 0123456789';
  }

  /// Builds preview text in the target script/language expressing:
  /// "[Country Name], [Target Language Name], [Monospace Font / Proportional Font]"
  String buildLocalizedPreviewText({required bool isMono}) {
    final monoLabel = _localizedMonoLabel(isMono);
    final countryAndLang = _localizedCountryAndLang();
    return '$countryAndLang，$monoLabel';
  }

  String _localizedMonoLabel(bool isMono) {
    if (scriptTag.contains('假名')) {
      return isMono ? '等幅フォント' : 'プロポーショナルフォント';
    }
    if (scriptTag.contains('谚文')) {
      return isMono ? '고정폭 글꼴' : '가변폭 글꼴';
    }
    if (scriptTag.contains('汉字') && name.contains('繁体')) {
      return isMono ? '等寬字型' : '比例字型';
    }
    if (scriptTag.contains('汉字')) {
      return isMono ? '等宽字体' : '比例字体';
    }
    if (scriptTag.contains('藏文')) {
      return isMono ? 'ཁྱབ་མཉམ་ཡིག་གཟུགས།' : 'སྣ་ཚོགས་ཡིག་གཟུགས།';
    }
    if (scriptTag.contains('阿拉伯文')) {
      return isMono ? 'خط ثابت العرض' : 'خط متناسب';
    }
    if (scriptTag.contains('泰文')) {
      return isMono ? 'แบบอักษรความกว้างเท่ากัน' : 'แบบอักษรสัดส่วน';
    }
    if (scriptTag.contains('越南语') || name.contains('越南')) {
      return isMono ? 'Phông chữ đơn cách' : 'Phông chữ tỷ lệ';
    }
    if (scriptTag.contains('缅甸文')) {
      return isMono ? 'ပုံသေအကျယ် ဖောင့်' : 'အချိုးကျ ဖောင့်';
    }
    if (scriptTag.contains('高棉文')) {
      return isMono ? 'ពុម្ពអក្សរទទឹងថេរ' : 'ពុម្ពអក្សរវិមាត្រ';
    }
    if (scriptTag.contains('老挝文')) {
      return isMono ? 'ຟອນຄວາມກວ້າງຄົງທີ່' : 'ຟອນສ່ວນປະສົມ';
    }
    if (scriptTag.contains('天城文')) {
      return isMono ? 'समस्थानिक फ़ॉन्ट' : 'आनुपातिक फ़ॉन्ट';
    }
    if (scriptTag.contains('孟加拉文')) {
      return isMono ? 'সমপ্রস্থ ফন্ট' : 'আনুপাতিক ফন্ট';
    }
    if (scriptTag.contains('泰米尔文')) {
      return isMono ? 'ஒரே அகல எழுத்துரு' : 'விகிதாசார எழுத்துரு';
    }
    if (scriptTag.contains('泰卢固文')) {
      return isMono ? 'సమాన వెడల్పు ఫాంట్' : 'నిష్పత్తి ఫాంట్';
    }
    if (scriptTag.contains('僧伽罗文')) {
      return isMono ? 'ස්ථාවර පරතර අකුරු' : 'අනුපාතික අකුරු';
    }
    if (scriptTag.contains('希伯来文')) {
      return isMono ? 'גופן ברווח קבוע' : 'גופן פרופורציונלי';
    }
    if (scriptTag.contains('希腊文')) {
      return isMono ? 'Γραμματοσειρά σταθερού πλάτους' : 'Αναλογική γραμματοσειρά';
    }
    if (scriptTag.contains('西里尔文')) {
      return isMono ? 'Моноширинный шрифт' : 'Пропорциональный шрифт';
    }
    if (countryTag.contains('法国') || name.contains('法语')) {
      return isMono ? 'Police à chasse fixe' : 'Police proportionnelle';
    }
    if (countryTag.contains('德国') || name.contains('德语')) {
      return isMono ? 'Festbreitenschrift' : 'Proportional-Schrift';
    }
    if (countryTag.contains('西班牙') || name.contains('西班牙语')) {
      return isMono ? 'Fuente de ancho fijo' : 'Fuente proporcional';
    }
    if (countryTag.contains('葡萄牙') || countryTag.contains('巴西') || name.contains('葡萄牙语')) {
      return isMono ? 'Fonte monoespaçada' : 'Fonte proporcional';
    }
    if (countryTag.contains('意大利') || name.contains('意大利语')) {
      return isMono ? 'Carattere a larghezza fissa' : 'Carattere proporzionale';
    }
    if (countryTag.contains('波兰') || name.contains('波兰语')) {
      return isMono ? 'Czcionka stałej szerokości' : 'Czcionka proporcjonalna';
    }
    if (countryTag.contains('捷克') || name.contains('捷克语')) {
      return isMono ? 'Písmo s pevnou šířkou' : 'Proporcionální písmo';
    }
    if (countryTag.contains('土耳其') || name.contains('土耳其语')) {
      return isMono ? 'Eşaralıklı Yazı Tipi' : 'Orantılı Yazı Tipi';
    }
    if (scriptTag.contains('彝文')) return isMono ? 'ꉙꌠꅔꇓ' : 'ꉙꌠꁱꂷ';
    if (scriptTag.contains('蒙古文')) return isMono ? 'ᠲᠡᠭᠰᠢ ᠦᠰᠦᠭ' : 'ᠬᠤᠪᠢᠣᠷ ᠦᠰᠦᠭ';
    if (scriptTag.contains('符号图形')) return isMono ? 'Monospace Font' : 'Proportional Font';

    return isMono ? 'Monospace Font' : 'Proportional Font';
  }

  String _localizedCountryAndLang() {
    switch (id) {
      case 'zh_cn': return '中国，简体中文';
      case 'zh_tw': return '中國，繁體中文';
      case 'bo_cn': return 'རྒྱ་ནག, བོད་ཡིག';
      case 'ug_cn': return 'جۇڭگو، ئۇيغۇرچە';
      case 'ii_cn': return 'ꏓꂱ，ꆈꌠꁱꂷ';
      case 'nushu_cn': return '中国，湖南江永女书';
      case 'dai_cn': return '中国，傣语/傣文';
      case 'ja_jp': return '日本、日本語';
      case 'ko_kr': return '대한민국, 한국어';
      case 'mn_mn': return 'ᠮᠣᠩᠭᠣᠯ, ᠮᠣᠩᠭᠣᠯ ᠬᠡᠯᠡ';
      case 'vi_vn': return 'Việt Nam, Tiếng Việt';
      case 'th_th': return 'ประเทศไทย, ภาษาไทย';
      case 'id_my': return 'Indonesia, Bahasa Indonesia';
      case 'mm_mm': return 'မြန်မာ, မြန်မာဘာသာ';
      case 'kh_kh': return 'កម្ពុជា, ភាសាខ្មែរ';
      case 'la_la': return 'ປະເທດລາວ, ພາສາລາວ';
      case 'hi_in': return 'भारत, हिन्दी';
      case 'bn_in': return 'বাংলাদেশ, বাংলা';
      case 'ta_in': return 'இந்தியா, தமிழ்';
      case 'te_in': return 'భారతదేశం, తెలుగు';
      case 'kn_in': return 'ಭಾರತ, ಕನ್ನಡ';
      case 'ml_in': return 'ഭാരതം, മലയാളം';
      case 'ur_pk': return 'پاکستان، اردو';
      case 'si_lk': return 'ශ්‍රී ලංකාව, සිංහල';
      case 'ar_sa': return 'المملكة العربية السعودية، العربية';
      case 'fa_ir': return 'ایران، فارسی';
      case 'he_il': return 'ישראל, עברית';
      case 'tr_tr': return 'Türkiye, Türkçe';
      case 'hy_am': return 'Հայաստան, Հայերեն';
      case 'ka_ge': return 'საქართველო, ქართული';
      case 'kz_kz': return 'Қазақстан, Қазақ тілі';
      case 'en_uk': return 'United Kingdom, English';
      case 'fr_fr': return 'France, Français';
      case 'de_de': return 'Deutschland, Deutsch';
      case 'es_es': return 'España, Español';
      case 'it_it': return 'Italia, Italiano';
      case 'pt_pt': return 'Portugal, Português';
      case 'pt_br': return 'Brasil, Português';
      case 'ru_ru': return 'Россия, Русский язык';
      case 'uk_ua': return 'Україна, Українська мова';
      case 'be_by': return 'Беларусь, Беларуская мова';
      case 'pl_pl': return 'Polska, Język polski';
      case 'cz_cz': return 'Česká republika, Čeština';
      case 'el_gr': return 'Ελλάδα, Ελληνικά';
      case 'sv_se': return 'Sverige, Svenska';
      case 'nl_nl': return 'Nederland, Nederlands';
      case 'en_us': return 'United States, English';
      case 'es_mx': return 'México, Español';
      case 'am_et': return 'ኢትዮጵያ, አማርኛ';
      case 'en_au': return 'Australia, English';
      case 'mi_nz': return 'Aotearoa, Te Reo Māori';
      case 'sym_digits': return '0123456789, Symbols';
      case 'sym_ui': return 'UI Graphics, ─│┌┐';
      default:
        return '$countryTag, $name';
    }
  }

  /// Derive continent tag automatically from [regionTag].
  static String deriveContinent(String regionTag) {
    switch (regionTag) {
      case '东亚':
      case '东南亚':
      case '南亚':
      case '中亚':
      case '西亚':
      case '亚洲':
        return '亚洲';
      case '北欧':
      case '西欧':
      case '中欧':
      case '南欧':
      case '东欧':
      case '欧洲':
        return '欧洲';
      case '北非':
      case '西非':
      case '中非':
      case '东非':
      case '南非':
      case '非洲':
        return '非洲';
      case '北美洲':
      case '中美洲':
      case '加勒比地区':
      case '南美洲':
      case '美洲':
        return '美洲';
      case '澳大拉西亚':
      case '美拉尼西亚':
      case '密克罗尼西亚':
      case '玻利尼西亚':
      case '大洋洲':
        return '大洋洲';
      default:
        return '符号与UI图形';
    }
  }

  LangBinding copyWith({
    String? fontPath,
    String? fontDisplayName,
    int? originalIndex,
    int? boundOrder,
    bool clearFontPath = false,
    bool clearFontDisplayName = false,
    bool clearBoundOrder = false,
  }) {
    return LangBinding(
      id: id,
      name: name,
      flag: flag,
      continentTag: continentTag,
      regionTag: regionTag,
      countryTag: countryTag,
      scriptTag: scriptTag,
      blocks: blocks,
      sample: sample,
      originalIndex: originalIndex ?? this.originalIndex,
      fontPath: clearFontPath ? null : (fontPath ?? this.fontPath),
      fontDisplayName: clearFontDisplayName
          ? null
          : (fontDisplayName ?? this.fontDisplayName),
      boundOrder: clearBoundOrder ? null : (boundOrder ?? this.boundOrder),
    );
  }

  /// Default preset national language profiles for international font extraction.
  static List<LangBinding> defaultPresets() {
    UnicodeBlock block(String name, int start, int end,
        {TextDir direction = TextDir.ltr}) {
      return UnicodeBlock(name, start, end, direction: direction);
    }

    final raw = [
      // ------------------------------------------------------------------
      // 1. 东亚 (East Asia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'zh_cn',
        name: '简体中文 (CJK)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '汉字',
        blocks: [
          block('CJK 统一表意文字', 0x4E00, 0x9FFF),
          block('CJK 符号与标点', 0x3000, 0x303F),
          block('半角及全角字符', 0xFF00, 0xFFEF),
        ],
      ),
      LangBinding(
        id: 'zh_tw',
        name: '繁体中文 (港台)',
        flag: '🇭🇰',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '汉字',
        blocks: [
          block('CJK 统一表意文字', 0x4E00, 0x9FFF),
          block('注音符号', 0x3100, 0x312F),
          block('CJK 符号与标点', 0x3000, 0x303F),
        ],
      ),
      LangBinding(
        id: 'bo_cn',
        name: '藏语 (藏文)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '藏文',
        blocks: [
          block('Tibetan 藏文', 0x0F00, 0x0FFF),
        ],
      ),
      LangBinding(
        id: 'ug_cn',
        name: '维吾尔语 (老维文)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
          block('Arabic Supplement', 0x0750, 0x077F, direction: TextDir.rtl),
          block('Arabic Presentation Forms-A', 0xFB50, 0xFDFF,
              direction: TextDir.rtl),
          block('Arabic Presentation Forms-B', 0xFE70, 0xFEFF,
              direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ii_cn',
        name: '彝语 (彝文)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '彝文',
        blocks: [
          block('Yi Syllables 彝文音节', 0xA000, 0xA48F),
          block('Yi Radicals 彝文字根', 0xA490, 0xA4CF),
        ],
      ),
      LangBinding(
        id: 'nushu_cn',
        name: '湖南江永女书',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '女书',
        blocks: [
          block('Nushu 女书', 0x1B170, 0x1B2FF),
        ],
      ),
      LangBinding(
        id: 'dai_cn',
        name: '傣语 (德宏&西双版纳傣文)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '傣文',
        blocks: [
          block('Tai Le 德宏傣文', 0x1950, 0x197F),
          block('New Tai Lue 西双版纳新傣文', 0x1980, 0x19DF),
          block('Tai Viet 傣文/新太文', 0xAA80, 0xAADF),
        ],
      ),
      LangBinding(
        id: 'xiaoerjing_cn',
        name: '回族 (小儿经)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
          block('Arabic Extended-A', 0x08A0, 0x08FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'za_cn',
        name: '壮语 (壮文与方块壮字 Sawndip)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '汉字/拉丁文',
        blocks: [
          block('Latin Extended-B (老壮文音调字母)', 0x0180, 0x024F),
          block('CJK 统一表意文字 (方块壮字 Sawndip)', 0x4E00, 0x9FFF),
        ],
      ),
      LangBinding(
        id: 'bai_cn',
        name: '白族 (方块白文僰文与白文拼音)',
        flag: '🇨🇳',
        regionTag: '东亚',
        countryTag: '中国',
        scriptTag: '汉字/拉丁文',
        blocks: [
          block('CJK 统一表意文字 (方块白文僰文)', 0x4E00, 0x9FFF),
          block('Latin Extended-A (白文拼音字母)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'ja_jp',
        name: '日语 (假名与常用汉字)',
        flag: '🇯🇵',
        regionTag: '东亚',
        countryTag: '日本',
        scriptTag: '假名',
        blocks: [
          block('Hiragana 平假名', 0x3040, 0x309F),
          block('Katakana 片假名', 0x30A0, 0x30FF),
          block('CJK 常用汉字', 0x4E00, 0x9FFF),
        ],
      ),
      LangBinding(
        id: 'ko_kr',
        name: '韩语/朝鲜语 (谚文)',
        flag: '🇰🇷',
        regionTag: '东亚',
        countryTag: '韩国/朝鲜',
        scriptTag: '谚文',
        blocks: [
          block('Hangul Syllables 韩文音节', 0xAC00, 0xD7AF),
          block('Hangul Jamo 韩文字母', 0x1100, 0x11FF),
        ],
      ),
      LangBinding(
        id: 'mn_mn',
        name: '蒙古语 (传统蒙古文)',
        flag: '🇲🇳',
        regionTag: '东亚',
        countryTag: '蒙古',
        scriptTag: '蒙古文',
        blocks: [
          block('Mongolian 传统蒙古文', 0x1800, 0x18AF),
        ],
      ),

      // ------------------------------------------------------------------
      // 2. 东南亚 (Southeast Asia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'vi_vn',
        name: '越南语 (国语字)',
        flag: '🇻🇳',
        regionTag: '东南亚',
        countryTag: '越南',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended Additional (越南语声调字母)', 0x1E00, 0x1EFF),
        ],
      ),
      LangBinding(
        id: 'th_th',
        name: '泰语',
        flag: '🇹🇭',
        regionTag: '东南亚',
        countryTag: '泰国',
        scriptTag: '泰文',
        blocks: [
          block('Thai 泰文', 0x0E00, 0x0E7F),
        ],
      ),
      LangBinding(
        id: 'id_my',
        name: '印尼语/马来语/他加录语',
        flag: '🇮🇩',
        regionTag: '东南亚',
        countryTag: '印尼/马来西亚/菲律宾',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'mm_mm',
        name: '缅甸语',
        flag: '🇲🇲',
        regionTag: '东南亚',
        countryTag: '缅甸',
        scriptTag: '缅甸文',
        blocks: [
          block('Myanmar 缅甸文', 0x1000, 0x109F),
        ],
      ),
      LangBinding(
        id: 'kh_kh',
        name: '高棉语',
        flag: '🇰🇭',
        regionTag: '东南亚',
        countryTag: '柬埔寨',
        scriptTag: '高棉文',
        blocks: [
          block('Khmer 高棉文', 0x1780, 0x17FF),
        ],
      ),
      LangBinding(
        id: 'la_la',
        name: '老挝语',
        flag: '🇱🇦',
        regionTag: '东南亚',
        countryTag: '老挝',
        scriptTag: '老挝文',
        blocks: [
          block('Lao 老挝文', 0x0E80, 0x0EFF),
        ],
      ),
      LangBinding(
        id: 'tl_tl',
        name: '德顿语/葡萄牙语',
        flag: '🇹🇱',
        regionTag: '东南亚',
        countryTag: '东帝汶',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 3. 南亚 (South Asia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'hi_in',
        name: '印地语/尼泊尔语 (天城文)',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度/尼泊尔',
        scriptTag: '天城文',
        blocks: [
          block('Devanagari 天城文', 0x0900, 0x097F),
        ],
      ),
      LangBinding(
        id: 'bn_in',
        name: '孟加拉语',
        flag: '🇧🇩',
        regionTag: '南亚',
        countryTag: '印度/孟加拉国',
        scriptTag: '孟加拉文',
        blocks: [
          block('Bengali 孟加拉文', 0x0980, 0x09FF),
        ],
      ),
      LangBinding(
        id: 'ta_in',
        name: '泰米尔语',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度/斯里兰卡',
        scriptTag: '泰米尔文',
        blocks: [
          block('Tamil 泰米尔文', 0x0B80, 0x0BFF),
        ],
      ),
      LangBinding(
        id: 'te_in',
        name: '泰卢固语',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度',
        scriptTag: '泰卢固文',
        blocks: [
          block('Telugu 泰卢固文', 0x0C00, 0x0C7F),
        ],
      ),
      LangBinding(
        id: 'kn_in',
        name: '卡纳达语',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度',
        scriptTag: '卡纳达文',
        blocks: [
          block('Kannada 卡纳达文', 0x0C80, 0x0CFF),
        ],
      ),
      LangBinding(
        id: 'ml_in',
        name: '马拉雅拉姆语',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度',
        scriptTag: '马拉雅拉姆文',
        blocks: [
          block('Malayalam 马拉雅拉姆文', 0x0D00, 0x0D7F),
        ],
      ),
      LangBinding(
        id: 'pa_in',
        name: '旁遮普语 (古木基文)',
        flag: '🇮🇳',
        regionTag: '南亚',
        countryTag: '印度',
        scriptTag: '古木基文',
        blocks: [
          block('Gurmukhi 旁遮普文/古木基文', 0x0A00, 0x0A7F),
        ],
      ),
      LangBinding(
        id: 'ur_pk',
        name: '乌尔都语',
        flag: '🇵🇰',
        regionTag: '南亚',
        countryTag: '巴基斯坦',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯及乌尔都书面', 0x0600, 0x06FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'si_lk',
        name: '僧伽罗语',
        flag: '🇱🇰',
        regionTag: '南亚',
        countryTag: '斯里兰卡',
        scriptTag: '僧伽罗文',
        blocks: [
          block('Sinhala 僧伽罗文', 0x0D80, 0x0DFF),
        ],
      ),
      LangBinding(
        id: 'dz_bt',
        name: '宗卡语 (藏文)',
        flag: '🇧🇹',
        regionTag: '南亚',
        countryTag: '不丹',
        scriptTag: '藏文',
        blocks: [
          block('Tibetan 藏文', 0x0F00, 0x0FFF),
        ],
      ),
      LangBinding(
        id: 'dv_mv',
        name: '迪维希语 (塔纳文)',
        flag: '🇲🇻',
        regionTag: '南亚',
        countryTag: '马尔代夫',
        scriptTag: '塔纳文',
        blocks: [
          block('Thaana 迪维希文/塔纳文', 0x0780, 0x07BF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ps_af',
        name: '普什图语/达里语',
        flag: '🇦🇫',
        regionTag: '南亚',
        countryTag: '阿富汗',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic Supplement (普什图语/达里语)', 0x0750, 0x077F,
              direction: TextDir.rtl),
        ],
      ),

      // ------------------------------------------------------------------
      // 4. 中亚 (Central Asia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'kz_kz',
        name: '哈萨克语 (西里尔文)',
        flag: '🇰🇿',
        regionTag: '中亚',
        countryTag: '哈萨克斯坦',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块及扩展', 0x0400, 0x052F),
        ],
      ),
      LangBinding(
        id: 'uz_uz',
        name: '乌兹别克语 (拉丁文/西里尔文)',
        flag: '🇺🇿',
        regionTag: '中亚',
        countryTag: '乌兹别克斯坦',
        scriptTag: '拉丁文/西里尔文',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
          block('Cyrillic 西里尔文', 0x0400, 0x04FF),
        ],
      ),
      LangBinding(
        id: 'kg_kg',
        name: '吉尔吉斯语 (西里尔文)',
        flag: '🇰🇬',
        regionTag: '中亚',
        countryTag: '吉尔吉斯斯坦',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块及补充', 0x0400, 0x052F),
        ],
      ),
      LangBinding(
        id: 'tj_tj',
        name: '塔吉克语 (西里尔文)',
        flag: '🇹🇯',
        regionTag: '中亚',
        countryTag: '塔吉克斯坦',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块及补充', 0x0400, 0x052F),
        ],
      ),
      LangBinding(
        id: 'tm_tm',
        name: '土库曼语 (拉丁文)',
        flag: '🇹🇲',
        regionTag: '中亚',
        countryTag: '土库曼斯坦',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 5. 西亚 (West Asia / 中东)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'ar_sa',
        name: '阿拉伯语',
        flag: '🇸🇦',
        regionTag: '西亚',
        countryTag: '沙特/阿联酋/卡塔尔/科威特/约旦/伊拉克',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
          block('Arabic Presentation Forms-B', 0xFE70, 0xFEFF,
              direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'fa_ir',
        name: '波斯语 (阿拉伯扩展)',
        flag: '🇮🇷',
        regionTag: '西亚',
        countryTag: '伊朗',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic Supplement (波斯语特有字母)', 0x0750, 0x077F,
              direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'he_il',
        name: '希伯来语',
        flag: '🇮🇱',
        regionTag: '西亚',
        countryTag: '以色列',
        scriptTag: '希伯来文',
        blocks: [
          block('Hebrew 希伯来文', 0x0590, 0x05FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'tr_tr',
        name: '土耳其语',
        flag: '🇹🇷',
        regionTag: '西亚',
        countryTag: '土耳其',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ğ, İ, Ş, ç, ö, ü)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'az_az',
        name: '阿塞拜疆语',
        flag: '🇦🇿',
        regionTag: '西亚',
        countryTag: '阿塞拜疆',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ə, Ğ, İ, Ö, Ş, Ü)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'hy_am',
        name: '亚美尼亚语',
        flag: '🇦🇲',
        regionTag: '西亚',
        countryTag: '亚美尼亚',
        scriptTag: '亚美尼亚文',
        blocks: [
          block('Armenian 亚美尼亚文', 0x0530, 0x058F),
        ],
      ),
      LangBinding(
        id: 'ka_ge',
        name: '格鲁吉亚语',
        flag: '🇬🇪',
        regionTag: '西亚',
        countryTag: '格鲁吉亚',
        scriptTag: '格鲁吉亚文',
        blocks: [
          block('Georgian 格鲁吉亚文', 0x10A0, 0x10FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 6. 北欧 (Northern Europe)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'sv_se',
        name: '瑞典语',
        flag: '🇸🇪',
        regionTag: '北欧',
        countryTag: '瑞典',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Å, Ä, Ö)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'da_dk',
        name: '丹麦语',
        flag: '🇩🇰',
        regionTag: '北欧',
        countryTag: '丹麦',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Æ, Ø, Å)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'no_no',
        name: '挪威语',
        flag: '🇳🇴',
        regionTag: '北欧',
        countryTag: '挪威',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Æ, Ø, Å)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'fi_fi',
        name: '芬兰语',
        flag: '🇫🇮',
        regionTag: '北欧',
        countryTag: '芬兰',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ä, Ö, Š, Ž)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'is_is',
        name: '冰岛语',
        flag: '🇮🇸',
        regionTag: '北欧',
        countryTag: '冰岛',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ð, ð, Þ, þ, Æ, Ö)', 0x0080, 0x00FF),
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'en_uk',
        name: '英语 (UK/ASCII)',
        flag: '🇬🇧',
        regionTag: '北欧',
        countryTag: '英国',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'ga_ie',
        name: '爱尔兰语 (盖尔语)',
        flag: '🇮🇪',
        regionTag: '北欧',
        countryTag: '爱尔兰',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Á, É, Í, Ó, Ú)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'et_ee',
        name: '爱沙尼亚语',
        flag: '🇪🇪',
        regionTag: '北欧',
        countryTag: '爱沙尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ä, Ö, Õ, Ü, Š, Ž)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'lv_lv',
        name: '拉脱维亚语',
        flag: '🇱🇻',
        regionTag: '北欧',
        countryTag: '拉脱维亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ā, Č, Ē, Ģ, Ī, Ķ, Ļ, Ņ, Š, Ū, Ž)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'lt_lt',
        name: '立陶宛语',
        flag: '🇱🇹',
        regionTag: '北欧',
        countryTag: '立陶宛',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ą, Č, Ę, Ė, Į, Š, Ų, Ū, Ž)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 7. 西欧 (Western Europe)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'fr_fr',
        name: '法语',
        flag: '🇫🇷',
        regionTag: '西欧',
        countryTag: '法国',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (À, Ç, É, È, Ê, Ë)', 0x0080, 0x00FF),
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'nl_nl',
        name: '荷兰语',
        flag: '🇳🇱',
        regionTag: '西欧',
        countryTag: '荷兰',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Latin Extended-A (Ĳ, ĳ)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'nl_be',
        name: '弗拉芒语/法语/德语',
        flag: '🇧🇪',
        regionTag: '西欧',
        countryTag: '比利时',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'lb_lu',
        name: '卢森堡语/法语/德语',
        flag: '🇱🇺',
        regionTag: '西欧',
        countryTag: '卢森堡',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'fr_mc',
        name: '法语',
        flag: '🇲🇨',
        regionTag: '西欧',
        countryTag: '摩纳哥',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 8. 中欧 (Central Europe)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'de_de',
        name: '德语',
        flag: '🇩🇪',
        regionTag: '中欧',
        countryTag: '德国',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ä, Ö, Ü, ß)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'de_at',
        name: '德语',
        flag: '🇦🇹',
        regionTag: '中欧',
        countryTag: '奥地利',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ä, Ö, Ü, ß)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'ch_ch',
        name: '德语/法语/意大利语/罗曼什语',
        flag: '🇨🇭',
        regionTag: '中欧',
        countryTag: '瑞士',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'pl_pl',
        name: '波兰语',
        flag: '🇵🇱',
        regionTag: '中欧',
        countryTag: '波兰',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ą, Ć, Ę, Ł, Ń, Ó, Ś, Ź, Ż)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'cz_cz',
        name: '捷克语',
        flag: '🇨🇿',
        regionTag: '中欧',
        countryTag: '捷克',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Á, Č, Ď, É, Ě, Í, Ň, Ó, Ř, Š, Ť, Ú, Ů, Ý, Ž)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'sk_sk',
        name: '斯洛伐克语',
        flag: '🇸🇰',
        regionTag: '中欧',
        countryTag: '斯洛伐克',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Á, Ä, Č, Ď, É, Í, Ĺ, Ľ, Ň, Ó, Ô, Ŕ, Š, Ť, Ú, Ý, Ž)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'hu_hu',
        name: '匈牙利语',
        flag: '🇭🇺',
        regionTag: '中欧',
        countryTag: '匈牙利',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Á, É, Í, Ó, Ö, Ő, Ú, Ü, Ű)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 9. 南欧 (Southern Europe)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'it_it',
        name: '意大利语',
        flag: '🇮🇹',
        regionTag: '南欧',
        countryTag: '意大利',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (À, È, É, Ì, Ò, Ù)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_es',
        name: '西班牙语',
        flag: '🇪🇸',
        regionTag: '南欧',
        countryTag: '西班牙',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ñ, Á, É, Í, Ó, Ú, ¿, ¡)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'pt_pt',
        name: '葡萄牙语',
        flag: '🇵🇹',
        regionTag: '南欧',
        countryTag: '葡萄牙',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement (Ã, Õ, Ç, Á, É, Í, Ó, Ú)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'el_gr',
        name: '希腊语 (古希腊文)',
        flag: '🇬🇷',
        regionTag: '南欧',
        countryTag: '希腊',
        scriptTag: '希腊文',
        blocks: [
          block('Greek and Coptic 希腊文', 0x0370, 0x03FF),
        ],
      ),
      LangBinding(
        id: 'mt_mt',
        name: '马耳他语/英语',
        flag: '🇲🇹',
        regionTag: '南欧',
        countryTag: '马耳他',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ċ, Ġ, Ħ, Ż)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'sr_rs',
        name: '塞尔维亚语 (西里尔文/拉丁文)',
        flag: '🇷🇸',
        regionTag: '南欧',
        countryTag: '塞尔维亚',
        scriptTag: '西里尔文/拉丁文',
        blocks: [
          block('Cyrillic 西里尔文主块', 0x0400, 0x04FF),
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'hr_hr',
        name: '克罗地亚语',
        flag: '🇭🇷',
        regionTag: '南欧',
        countryTag: '克罗地亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Č, Ć, Đ, Š, Ž)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'bs_ba',
        name: '波斯尼亚语',
        flag: '🇧🇦',
        regionTag: '南欧',
        countryTag: '波斯尼亚和黑塞哥维那',
        scriptTag: '拉丁文/西里尔文',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
          block('Cyrillic 西里尔文', 0x0400, 0x04FF),
        ],
      ),
      LangBinding(
        id: 'me_me',
        name: '黑山语',
        flag: '🇲🇪',
        regionTag: '南欧',
        countryTag: '黑山',
        scriptTag: '拉丁文/西里尔文',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
          block('Cyrillic 西里尔文', 0x0400, 0x04FF),
        ],
      ),
      LangBinding(
        id: 'mk_mk',
        name: '马其顿语',
        flag: '🇲🇰',
        regionTag: '南欧',
        countryTag: '北马其顿',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块及扩展', 0x0400, 0x052F),
        ],
      ),
      LangBinding(
        id: 'sq_al',
        name: '阿尔巴尼亚语',
        flag: '🇦🇱',
        regionTag: '南欧',
        countryTag: '阿尔巴尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ç, Ë)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'sl_si',
        name: '斯洛文尼亚语',
        flag: '🇸🇮',
        regionTag: '南欧',
        countryTag: '斯洛文尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Č, Š, Ž)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 10. 东欧 (Eastern Europe)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'ru_ru',
        name: '俄语 (西里尔文)',
        flag: '🇷🇺',
        regionTag: '东欧',
        countryTag: '俄罗斯',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块', 0x0400, 0x04FF),
        ],
      ),
      LangBinding(
        id: 'uk_ua',
        name: '乌克兰语 (西里尔文)',
        flag: '🇺🇦',
        regionTag: '东欧',
        countryTag: '乌克兰',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块', 0x0400, 0x04FF),
          block('Cyrillic Supplement 补充(含 І, Ї, Є, Ґ)', 0x0500, 0x052F),
        ],
      ),
      LangBinding(
        id: 'be_by',
        name: '白俄罗斯语 (西里尔文)',
        flag: '🇧🇾',
        regionTag: '东欧',
        countryTag: '白俄罗斯',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块及补充', 0x0400, 0x052F),
        ],
      ),
      LangBinding(
        id: 'ro_ro',
        name: '罗马尼亚语',
        flag: '🇷🇴',
        regionTag: '东欧',
        countryTag: '罗马尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ă, Â, Î, Ș, Ț)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'bg_bg',
        name: '保加利亚语 (西里尔文)',
        flag: '🇧🇬',
        regionTag: '东欧',
        countryTag: '保加利亚',
        scriptTag: '西里尔文',
        blocks: [
          block('Cyrillic 西里尔文主块', 0x0400, 0x04FF),
        ],
      ),
      LangBinding(
        id: 'md_md',
        name: '摩尔多瓦语 (罗马尼亚语)',
        flag: '🇲🇩',
        regionTag: '东欧',
        countryTag: '摩尔多瓦',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin Extended-A (Ă, Â, Î, Ș, Ț)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 11. 北非 (North Africa)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'ar_eg',
        name: '埃及阿拉伯语',
        flag: '🇪🇬',
        regionTag: '北非',
        countryTag: '埃及',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ar_dz',
        name: '阿拉伯语/柏柏尔语',
        flag: '🇩🇿',
        regionTag: '北非',
        countryTag: '阿尔及利亚',
        scriptTag: '阿拉伯文/提非纳文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
          block('Tifinagh 提非纳文', 0x2D30, 0x2D7F),
        ],
      ),
      LangBinding(
        id: 'ar_ma',
        name: '阿拉伯语/柏柏尔语',
        flag: '🇲🇦',
        regionTag: '北非',
        countryTag: '摩洛哥',
        scriptTag: '阿拉伯文/提非纳文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
          block('Tifinagh 提非纳文', 0x2D30, 0x2D7F),
        ],
      ),
      LangBinding(
        id: 'ar_tn',
        name: '阿拉伯语/法语',
        flag: '🇹🇳',
        regionTag: '北非',
        countryTag: '突尼斯',
        scriptTag: '阿拉伯文/拉丁文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ar_ly',
        name: '阿拉伯语',
        flag: '🇱🇾',
        regionTag: '北非',
        countryTag: '利比亚',
        scriptTag: '阿拉伯文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ar_sd',
        name: '阿拉伯语/英语',
        flag: '🇸🇩',
        regionTag: '北非',
        countryTag: '苏丹',
        scriptTag: '阿拉伯文/拉丁文',
        blocks: [
          block('Arabic 阿拉伯文主块', 0x0600, 0x06FF, direction: TextDir.rtl),
        ],
      ),

      // ------------------------------------------------------------------
      // 12. 西非 (West Africa)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'ha_ng',
        name: '豪萨语/约鲁巴语/伊博语/英语',
        flag: '🇳🇬',
        regionTag: '西非',
        countryTag: '尼日利亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin Extended-B (非洲音标/特殊字母)', 0x0180, 0x024F),
        ],
      ),
      LangBinding(
        id: 'wo_sn',
        name: '沃洛夫语/法语/N\'Ko文',
        flag: '🇸🇳',
        regionTag: '西非',
        countryTag: '塞内加尔',
        scriptTag: '拉丁文/N\'Ko文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('N\'Ko 西非书面文字', 0x07C0, 0x07FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'ak_gh',
        name: '阿坎语/特威语/英语',
        flag: '🇬🇭',
        regionTag: '西非',
        countryTag: '加纳',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin Extended-B (Ɛ, Ɔ, Ŋ)', 0x0180, 0x024F),
        ],
      ),
      LangBinding(
        id: 'bm_ml',
        name: '班巴拉语/N\'Ko文',
        flag: '🇲🇱',
        regionTag: '西非',
        countryTag: '马里',
        scriptTag: 'N\'Ko文/拉丁文',
        blocks: [
          block('N\'Ko 西非书面文字', 0x07C0, 0x07FF, direction: TextDir.rtl),
          block('Latin Extended-B', 0x0180, 0x024F),
        ],
      ),
      LangBinding(
        id: 'vai_lr',
        name: '瓦伊语 (Vai音节文字)',
        flag: '🇱🇷',
        regionTag: '西非',
        countryTag: '利比里亚',
        scriptTag: '瓦伊文',
        blocks: [
          block('Vai 瓦伊文', 0xA500, 0xA63F),
        ],
      ),
      LangBinding(
        id: 'fr_ci',
        name: '法语/朱拉语',
        flag: '🇨🇮',
        regionTag: '西非',
        countryTag: '科特迪瓦',
        scriptTag: '拉丁文/N\'Ko文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('N\'Ko 西非书面文字', 0x07C0, 0x07FF, direction: TextDir.rtl),
        ],
      ),
      LangBinding(
        id: 'fr_gn',
        name: '法语/曼丁哥语',
        flag: '🇬🇳',
        regionTag: '西非',
        countryTag: '几内亚',
        scriptTag: '拉丁文/N\'Ko文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('N\'Ko 西非书面文字', 0x07C0, 0x07FF, direction: TextDir.rtl),
        ],
      ),

      // ------------------------------------------------------------------
      // 13. 中非 (Central Africa)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'ln_cd',
        name: '林加拉语/斯瓦希里语/法语',
        flag: '🇨🇩',
        regionTag: '中非',
        countryTag: '刚果民主共和国',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'ln_cg',
        name: '林加拉语/法语',
        flag: '🇨🇬',
        regionTag: '中非',
        countryTag: '刚果共和国',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'bam_cm',
        name: '法语/英语/巴姆穆文字',
        flag: '🇨🇲',
        regionTag: '中非',
        countryTag: '喀麦隆',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'sg_cf',
        name: '桑戈语/法语',
        flag: '🇨🇫',
        regionTag: '中非',
        countryTag: '中非共和国',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 14. 东非 (East Africa)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'am_et',
        name: '阿姆哈拉语/奥罗莫语 (吉兹文)',
        flag: '🇪🇹',
        regionTag: '东非',
        countryTag: '埃塞俄比亚',
        scriptTag: '吉兹文',
        blocks: [
          block('Ethiopic 吉兹/埃塞俄比亚文', 0x1200, 0x137F),
        ],
      ),
      LangBinding(
        id: 'sw_ke',
        name: '斯瓦希里语/英语',
        flag: '🇰🇪',
        regionTag: '东非',
        countryTag: '肯尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'sw_tz',
        name: '斯瓦希里语',
        flag: '🇹🇿',
        regionTag: '东非',
        countryTag: '坦桑尼亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'lg_ug',
        name: '干达语/斯瓦希里语/英语',
        flag: '🇺🇬',
        regionTag: '东非',
        countryTag: '乌干达',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'rw_rw',
        name: '卢旺达语',
        flag: '🇷🇼',
        regionTag: '东非',
        countryTag: '卢旺达',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'so_so',
        name: '索马里语 (奥斯曼亚文/拉丁文)',
        flag: '🇸🇴',
        regionTag: '东非',
        countryTag: '索马里',
        scriptTag: '奥斯曼亚文/拉丁文',
        blocks: [
          block('Osmanya 奥斯曼亚文', 0x10480, 0x104AF),
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'ti_er',
        name: '提格雷尼亚语 (吉兹文)',
        flag: '🇪🇷',
        regionTag: '东非',
        countryTag: '厄立特里亚',
        scriptTag: '吉兹文',
        blocks: [
          block('Ethiopic 吉兹/埃塞俄比亚文', 0x1200, 0x137F),
        ],
      ),
      LangBinding(
        id: 'mg_mg',
        name: '马达加斯加语',
        flag: '🇲🇬',
        regionTag: '东非',
        countryTag: '马达加斯加',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),

      // ------------------------------------------------------------------
      // 15. 南非 (Southern Africa)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'zu_za',
        name: '祖鲁语/科萨语/南非荷兰语',
        flag: '🇿🇦',
        regionTag: '南非',
        countryTag: '南非共和国',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Latin Extended-B', 0x0180, 0x024F),
        ],
      ),
      LangBinding(
        id: 'pt_ao',
        name: '葡萄牙语/姆本杜语',
        flag: '🇦🇴',
        regionTag: '南非',
        countryTag: '安哥拉',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'pt_mz',
        name: '葡萄牙语/玛快语',
        flag: '🇲🇿',
        regionTag: '南非',
        countryTag: '莫桑比克',
        scriptTag: '拉丁文',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'sn_zw',
        name: '绍纳语/北德贝莱语',
        flag: '🇿🇼',
        regionTag: '南非',
        countryTag: '津巴布韦',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'tn_bw',
        name: '茨瓦纳语',
        flag: '🇧🇼',
        regionTag: '南非',
        countryTag: '博茨瓦纳',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'ny_mw',
        name: '齐切瓦语',
        flag: '🇲🇼',
        regionTag: '南非',
        countryTag: '马拉维',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'st_ls',
        name: '塞索托语',
        flag: '🇱🇸',
        regionTag: '南非',
        countryTag: '莱索托',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),

      // ------------------------------------------------------------------
      // 16. 北美洲 (North America)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'en_us',
        name: '英语/切罗基语/原住民语',
        flag: '🇺🇸',
        regionTag: '北美洲',
        countryTag: '美国',
        scriptTag: '拉丁文/切罗基文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Cherokee 切罗基文', 0x13A0, 0x13FF),
        ],
      ),
      LangBinding(
        id: 'en_ca',
        name: '英语/法语/因纽特语(音节文字)',
        flag: '🇨🇦',
        regionTag: '北美洲',
        countryTag: '加拿大',
        scriptTag: '拉丁文/原住民音节文字',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Unified Canadian Aboriginal Syllabics 加拿大原住民音节文字', 0x1400, 0x167F),
        ],
      ),
      LangBinding(
        id: 'es_mx',
        name: '西班牙语/纳瓦特尔语/玛雅语',
        flag: '🇲🇽',
        regionTag: '北美洲',
        countryTag: '墨西哥',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement (Ñ, Á, É, Í, Ó, Ú)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'kl_gl',
        name: '格陵兰语/丹麦语',
        flag: '🇬🇱',
        regionTag: '北美洲',
        countryTag: '格陵兰',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement (Å, Æ, Ø)', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 17. 中美洲 (Central America)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'es_gt',
        name: '西班牙语/玛雅语系',
        flag: '🇬🇹',
        regionTag: '中美洲',
        countryTag: '危地马拉',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'en_bz',
        name: '英语/克里奥尔语/玛雅语',
        flag: '🇧🇿',
        regionTag: '中美洲',
        countryTag: '伯利兹',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'es_sv',
        name: '西班牙语/纳瓦特语',
        flag: '🇸🇻',
        regionTag: '中美洲',
        countryTag: '萨尔瓦多',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_hn',
        name: '西班牙语/密斯基托语',
        flag: '🇭🇳',
        regionTag: '中美洲',
        countryTag: '洪都拉斯',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_ni',
        name: '西班牙语/密斯基托语',
        flag: '🇳🇮',
        regionTag: '中美洲',
        countryTag: '尼加拉瓜',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_cr',
        name: '西班牙语/布里布里语',
        flag: '🇨🇷',
        regionTag: '中美洲',
        countryTag: '哥斯达黎加',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_pa',
        name: '西班牙语/库纳语',
        flag: '🇵🇦',
        regionTag: '中美洲',
        countryTag: '巴拿马',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 18. 加勒比地区 (Caribbean)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'es_cu',
        name: '西班牙语',
        flag: '🇨🇺',
        regionTag: '加勒比地区',
        countryTag: '古巴',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'ht_ht',
        name: '海地克里奥尔语/法语',
        flag: '🇭🇹',
        regionTag: '加勒比地区',
        countryTag: '海地',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_do',
        name: '西班牙语',
        flag: '🇩🇴',
        regionTag: '加勒比地区',
        countryTag: '多米尼加',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'en_jm',
        name: '英语/帕瓦语(Patois)',
        flag: '🇯🇲',
        regionTag: '加勒比地区',
        countryTag: '牙买加',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'en_tt',
        name: '英语/克里奥尔语/印地语',
        flag: '🇹🇹',
        regionTag: '加勒比地区',
        countryTag: '特立尼达和多巴哥',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'en_bs',
        name: '英语/巴哈马克里奥尔语',
        flag: '🇧🇸',
        regionTag: '加勒比地区',
        countryTag: '巴哈马',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),

      // ------------------------------------------------------------------
      // 19. 南美洲 (South America)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'pt_br',
        name: '葡萄牙语/瓜拉尼语',
        flag: '🇧🇷',
        regionTag: '南美洲',
        countryTag: '巴西',
        scriptTag: '拉丁文变音符号',
        blocks: [
          block('Latin-1 Supplement (Ã, Õ, Ç, Á, É, Í, Ó, Ú)', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_ar',
        name: '西班牙语/瓜拉尼语/克丘亚语',
        flag: '🇦🇷',
        regionTag: '南美洲',
        countryTag: '阿根廷',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_co',
        name: '西班牙语/瓦优语',
        flag: '🇨🇴',
        regionTag: '南美洲',
        countryTag: '哥伦比亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_pe',
        name: '西班牙语/克丘亚语/艾马拉语',
        flag: '🇵🇪',
        regionTag: '南美洲',
        countryTag: '秘鲁',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_cl',
        name: '西班牙语/马普切语',
        flag: '🇨🇱',
        regionTag: '南美洲',
        countryTag: '智利',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_ve',
        name: '西班牙语/瓦劳语',
        flag: '🇻🇪',
        regionTag: '南美洲',
        countryTag: '委内瑞拉',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_ec',
        name: '西班牙语/基切瓦语',
        flag: '🇪🇨',
        regionTag: '南美洲',
        countryTag: '厄瓜多尔',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'es_bo',
        name: '西班牙语/克丘亚语/艾马拉语',
        flag: '🇧🇴',
        regionTag: '南美洲',
        countryTag: '玻利维亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'gn_py',
        name: '瓜拉尼语/西班牙语',
        flag: '🇵🇾',
        regionTag: '南美洲',
        countryTag: '巴拉圭',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Latin Extended-A (G̃, g̃, Ã, Ẽ, Ĩ, Õ, Ũ, Ỹ)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'es_uy',
        name: '西班牙语',
        flag: '🇺🇾',
        regionTag: '南美洲',
        countryTag: '乌拉圭',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'en_gy',
        name: '英语/圭亚那克里奥尔语',
        flag: '🇬🇾',
        regionTag: '南美洲',
        countryTag: '圭亚那',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'nl_sr',
        name: '荷兰语/苏里南汤加语',
        flag: '🇸🇷',
        regionTag: '南美洲',
        countryTag: '苏里南',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
          block('Latin Extended-A (Ĳ, ĳ)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 20. 澳大拉西亚 (Australasia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'en_au',
        name: '英语/土著原住民语',
        flag: '🇦🇺',
        regionTag: '澳大拉西亚',
        countryTag: '澳大利亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'mi_nz',
        name: '毛利语/英语',
        flag: '🇳🇿',
        regionTag: '澳大拉西亚',
        countryTag: '新西兰',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin Extended-A (Ā, Ē, Ī, Ō, Ū)', 0x0100, 0x017F),
        ],
      ),

      // ------------------------------------------------------------------
      // 21. 美拉尼西亚 (Melanesia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'tpi_pg',
        name: '托克皮辛语/希里莫图语/英语',
        flag: '🇵🇬',
        regionTag: '美拉尼西亚',
        countryTag: '巴布亚新几内亚',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'fj_fj',
        name: '斐济语/斐济印地语/英语',
        flag: '🇫🇯',
        regionTag: '美拉尼西亚',
        countryTag: '斐济',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'pis_sb',
        name: '所罗门皮钦语/英语',
        flag: '🇸🇧',
        regionTag: '美拉尼西亚',
        countryTag: '所罗门群岛',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'bi_vu',
        name: '比斯拉马语/法语/英语',
        flag: '🇻🇺',
        regionTag: '美拉尼西亚',
        countryTag: '瓦努阿图',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'fr_nc',
        name: '法语/卡纳克语',
        flag: '🇳🇨',
        regionTag: '美拉尼西亚',
        countryTag: '新喀里多尼亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),

      // ------------------------------------------------------------------
      // 22. 密克罗尼西亚 (Micronesia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'en_fm',
        name: '英语/楚克语/波纳佩语',
        flag: '🇫🇲',
        regionTag: '密克罗尼西亚',
        countryTag: '密克罗尼西亚联邦',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'mh_mh',
        name: '马绍尔语/英语',
        flag: '🇲🇭',
        regionTag: '密克罗尼西亚',
        countryTag: '马绍尔群岛',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin Extended-A (M̧, Ņ, O̧, Ļ)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'pau_pw',
        name: '帕劳语/英语',
        flag: '🇵🇼',
        regionTag: '密克罗尼西亚',
        countryTag: '帕劳',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'na_nr',
        name: '瑙鲁语/英语',
        flag: '🇳🇷',
        regionTag: '密克罗尼西亚',
        countryTag: '瑙鲁',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin Extended-A (Ẽ, Ĩ, Õ, Ũ)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'gil_ki',
        name: '基里巴斯语/英语',
        flag: '🇰🇮',
        regionTag: '密克罗尼西亚',
        countryTag: '基里巴斯',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),

      // ------------------------------------------------------------------
      // 23. 玻利尼西亚 (Polynesia)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'sm_ws',
        name: '萨摩亚语/英语',
        flag: '🇼🇸',
        regionTag: '玻利尼西亚',
        countryTag: '萨摩亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin Extended-A (ā, ē, ī, ō, ū)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'to_to',
        name: '汤加语/英语',
        flag: '🇹🇴',
        regionTag: '玻利尼西亚',
        countryTag: '汤加',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
          block('Latin Extended-A (Ā, Ē, Ī, Ō, Ū)', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'tv_tv',
        name: '图瓦卢语/英语',
        flag: '🇹🇻',
        regionTag: '玻利尼西亚',
        countryTag: '图瓦卢',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),
      LangBinding(
        id: 'rar_ck',
        name: '库克群岛毛利语/英语',
        flag: '🇨🇰',
        regionTag: '玻利尼西亚',
        countryTag: '库克群岛',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin Extended-A', 0x0100, 0x017F),
        ],
      ),
      LangBinding(
        id: 'ty_pf',
        name: '塔希提语/法语',
        flag: '🇵🇫',
        regionTag: '玻利尼西亚',
        countryTag: '法属玻利尼西亚',
        scriptTag: '拉丁文扩展',
        blocks: [
          block('Latin-1 Supplement', 0x0080, 0x00FF),
        ],
      ),
      LangBinding(
        id: 'niu_nu',
        name: '纽埃语/英语',
        flag: '🇳🇺',
        regionTag: '玻利尼西亚',
        countryTag: '纽埃',
        scriptTag: '拉丁文',
        blocks: [
          block('Basic Latin (ASCII)', 0x0000, 0x007F),
        ],
      ),

      // ------------------------------------------------------------------
      // 8. 符号与 UI 图形 (Symbols & UI Graphics)
      // ------------------------------------------------------------------
      LangBinding(
        id: 'sym_digits',
        name: '通用数字与标点符号',
        flag: '🔢',
        regionTag: '符号与UI图形',
        countryTag: '通用',
        scriptTag: '符号图形',
        blocks: [
          block('常用标点与通用符号', 0x2000, 0x206F),
          block('货币符号 (\$ € ¥ £ ฿ ₹)', 0x20A0, 0x20CF),
        ],
      ),
      LangBinding(
        id: 'sym_ui',
        name: '嵌入式 UI 界面框线与制表符',
        flag: '🔣',
        regionTag: '符号与UI图形',
        countryTag: '通用',
        scriptTag: '符号图形',
        blocks: [
          block('Box Drawing 制表符 (─│┌┐└┘├┤)', 0x2500, 0x257F),
          block('Block Elements 方块元素 (█ ▌ ▐ ▀ ▄)', 0x2580, 0x259F),
          block('Geometric Shapes 几何图形 (▲▼◆●■)', 0x25A0, 0x25FF),
          block('Arrows 箭头符号 (←↑→↓)', 0x2190, 0x21FF),
        ],
      ),
    ];
    return List.generate(raw.length, (i) => raw[i].copyWith(originalIndex: i));
  }
}
