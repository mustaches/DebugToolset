// ignore_for_file: avoid_print
void main() {
  int startI = 0;
  int endI = 10;
  List<int> states = [0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1];
  double baseY = 100.0;
  double amplitude = 20.0;
  double activeScale = 10.0;

  bool firstPoint = true;
  int prevState = 0;
  for (int i = startI; i <= endI; i++) {
    double x = i.toDouble() * activeScale;
    int bitState = states[i];
    double y = baseY - (bitState * amplitude);

    if (firstPoint) {
      print('moveTo($x, $y)');
      firstPoint = false;
    } else if (bitState != prevState) {
      double prevY = baseY - (prevState * amplitude);
      print('lineTo($x, $prevY)');
      print('lineTo($x, $y)');
    }
    
    if (i == endI) {
      print('lineTo($x, $y) (end)');
    }
    prevState = bitState;
  }
}
