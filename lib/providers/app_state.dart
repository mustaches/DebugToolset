import 'package:flutter/material.dart';

class AppState extends ChangeNotifier {
  int _selectedModuleIndex = 0;

  int get selectedModuleIndex => _selectedModuleIndex;

  void setModuleIndex(int index) {
    if (_selectedModuleIndex != index) {
      _selectedModuleIndex = index;
      notifyListeners();
    }
  }
}
