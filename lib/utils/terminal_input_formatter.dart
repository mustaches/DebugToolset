import 'package:flutter/services.dart';

class AsciiInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.runes.any((r) => r > 127)) {
      return oldValue;
    }
    return newValue;
  }
}

class HexInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String text = newValue.text.toUpperCase().replaceAll(RegExp(r'[^0-9A-F\s]'), '');
    List<String> chunks = text.split(RegExp(r'\s+'));
    StringBuffer sb = StringBuffer();
    
    for (int i = 0; i < chunks.length; i++) {
      String chunk = chunks[i];
      if (chunk.isEmpty) continue;
      
      if (chunk.length > 2) {
         String temp = chunk;
         while(temp.length > 2) {
           sb.write('${temp.substring(0,2)} ');
           temp = temp.substring(2);
         }
         chunk = temp;
      }
      
      if (chunk.length == 1) {
        if (i < chunks.length - 1 || text.endsWith(' ')) {
          chunk = '0$chunk';
        }
      }
      
      sb.write(chunk);
      if (i < chunks.length - 1) sb.write(' ');
    }
    
    if (text.endsWith(' ') && !sb.toString().endsWith(' ')) {
      sb.write(' ');
    }

    String finalString = sb.toString();
    return TextEditingValue(
      text: finalString,
      selection: TextSelection.collapsed(offset: finalString.length),
    );
  }
}
