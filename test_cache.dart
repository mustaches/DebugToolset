// ignore_for_file: avoid_print
void main() {
  int maxPoints = 8388608;
  int chunkSize = 4096;
  int head = 4000000;
  int startIndex = head;
  int startI = 7999000;
  int endI = 8001000;
  int pointsPerPixel = 10000;

  for (int i = startI; i <= endI; i += pointsPerPixel) {
    int chunkEnd = i + pointsPerPixel - 1;
    if (chunkEnd > endI) chunkEnd = endI;

    print('Pixel starting at $i, chunkEnd $chunkEnd');

    for (int j = i; j <= chunkEnd; ) {
      int bufferIdx = (startIndex + j) % maxPoints;
      int offsetInChunk = bufferIdx % chunkSize;
      int remainingInLoop = chunkEnd - j + 1;

      if (offsetInChunk == 0 && remainingInLoop >= chunkSize) {
        int cacheIdx = bufferIdx ~/ chunkSize;
        print('  Using cache $cacheIdx for $chunkSize points');
        j += chunkSize;
      } else {
        print('  Point-by-point at $bufferIdx');
        j++;
      }
      
      // Stop printing point-by-point too much
      if (offsetInChunk != 0 && j == i + 5) {
        int nextAlign = chunkSize - offsetInChunk;
        if (remainingInLoop > nextAlign) {
           j += nextAlign - 5;
           print('  ... skipping point-by-point to next align');
        }
      }
    }
  }
}
