// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  // --- 1. Update OscilloscopeState ---
  File stateFile = File('lib/providers/oscilloscope_state.dart');
  String stateCode = stateFile.readAsStringSync();
  
  // Replace the old I2C matching condition block
  String oldI2cBlock = '''
          if (targetSequence.isNotEmpty) {
             bool foundSequence = false;
             if (targetSequence.length == 1) {
                foundSequence = frameRegAddr == targetSequence[0] || frameData.contains(targetSequence[0]);
             } else {
                List<int> allBytes = [];
                if (frameRegAddr != null) allBytes.add(frameRegAddr);
                allBytes.addAll(frameData);
                
                for (int i = 0; i <= allBytes.length - targetSequence.length; i++) {
                   bool match = true;
                   for (int j = 0; j < targetSequence.length; j++) {
                      if (allBytes[i+j] != targetSequence[j]) {
                         match = false;
                         break;
                      }
                   }
                   if (match) {
                      foundSequence = true;
                      break;
                   }
                }
             }
             if (!foundSequence) continue;
          }
          
          searchMatches.add(BusSearchMatch(time: frame.startIndex / _sampleRate, startIndex: frame.startIndex, endIndex: frame.endIndex, busName: bus.name));
''';

  String newI2cBlock = '''
          if (targetSequence.isNotEmpty) {
             bool foundSequence = false;
             int matchStartIndex = -1;
             int matchEndIndex = -1;
             
             List<ProtocolPacket> searchablePackets = [];
             bool isFirst = true;
             for (int idx = 0; idx < frame.packets.length; idx++) {
                var p = frame.packets[idx];
                if (p.type == PacketType.data && p.rawValue != null) {
                   if (isWritePhase && isFirst) {
                      isFirst = false;
                      // Include register address in searchable packets
                      searchablePackets.add(p);
                   } else {
                      searchablePackets.add(p);
                   }
                }
             }
             
             if (targetSequence.length == 1) {
                for (var p in searchablePackets) {
                   if (p.rawValue == targetSequence[0]) {
                      foundSequence = true;
                      matchStartIndex = p.startIndex;
                      matchEndIndex = p.endIndex;
                      break;
                   }
                }
             } else {
                for (int i = 0; i <= searchablePackets.length - targetSequence.length; i++) {
                   bool match = true;
                   for (int j = 0; j < targetSequence.length; j++) {
                      if (searchablePackets[i+j].rawValue != targetSequence[j]) {
                         match = false;
                         break;
                      }
                   }
                   if (match) {
                      foundSequence = true;
                      matchStartIndex = searchablePackets[i].startIndex;
                      matchEndIndex = searchablePackets[i+targetSequence.length-1].endIndex;
                      break;
                   }
                }
             }
             
             if (!foundSequence) continue;
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          } else {
             int matchStartIndex = frame.startIndex;
             int matchEndIndex = frame.endIndex;
             
             if (i2cRegisterAddress != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.data && p.rawValue == i2cRegisterAddress) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             } else if (i2cDeviceAddress != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.address && p.rawValue == i2cDeviceAddress) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             }
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          }
''';

  if (stateCode.contains(oldI2cBlock)) {
     stateCode = stateCode.replaceFirst(oldI2cBlock, newI2cBlock);
     stateFile.writeAsStringSync(stateCode);
     print('Updated oscilloscope_state.dart');
  } else {
     print('Failed to find oldI2cBlock in oscilloscope_state.dart');
  }

  // --- 2. Update ChartWidget ---
  File chartFile = File('lib/modules/oscilloscope/widgets/chart_widget.dart');
  String chartCode = chartFile.readAsStringSync();
  
  String packetDrawBlock = '''
            bool skipDrawing = false;
            if (x2 - x1 < 2.0) {
              if (x1 < lastDrawnPixel[lane] + 2.0) {
                skipDrawing = true;
              } else {
                lastDrawnPixel[lane] = x1;
              }
            }

            if (!skipDrawing) {
              paint.color = packet.color.withValues(alpha: 0.8);
              paint.style = PaintingStyle.fill;
              
              if (x2 - x1 < 2 * dx) {
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
                paint.style = PaintingStyle.stroke;
                paint.color = Colors.white;
                paint.strokeWidth = 1.0;
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
              } else {
                Path path = Path();
                path.moveTo(x1, midY);
                path.lineTo(x1 + dx, topY);
                path.lineTo(x2 - dx, topY);
                path.lineTo(x2, midY);
                path.lineTo(x2 - dx, bottomY);
                path.lineTo(x1 + dx, bottomY);
                path.close();
                canvas.drawPath(path, paint);
                
                paint.style = PaintingStyle.stroke;
                paint.color = Colors.white;
                paint.strokeWidth = 1.0;
                canvas.drawPath(path, paint);
              }
''';

  String newPacketDrawBlock = '''
            bool skipDrawing = false;
            if (x2 - x1 < 2.0) {
              if (x1 < lastDrawnPixel[lane] + 2.0) {
                skipDrawing = true;
              } else {
                lastDrawnPixel[lane] = x1;
              }
            }

            if (!skipDrawing) {
              bool isHighlightedMatch = false;
              if (state.searchMatches.isNotEmpty && state.currentSearchMatchIndex >= 0 && state.currentSearchMatchIndex < state.searchMatches.length) {
                  var match = state.searchMatches[state.currentSearchMatchIndex];
                  if (match.busName == bus.name && packet.startIndex >= match.startIndex && packet.endIndex <= match.endIndex) {
                      isHighlightedMatch = true;
                  }
              }

              paint.color = isHighlightedMatch ? packet.color.withValues(alpha: 1.0) : packet.color.withValues(alpha: 0.8);
              paint.style = PaintingStyle.fill;
              
              if (x2 - x1 < 2 * dx) {
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
                paint.style = PaintingStyle.stroke;
                paint.color = isHighlightedMatch ? Colors.yellowAccent : Colors.white;
                paint.strokeWidth = isHighlightedMatch ? 3.0 : 1.0;
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
              } else {
                Path path = Path();
                path.moveTo(x1, midY);
                path.lineTo(x1 + dx, topY);
                path.lineTo(x2 - dx, topY);
                path.lineTo(x2, midY);
                path.lineTo(x2 - dx, bottomY);
                path.lineTo(x1 + dx, bottomY);
                path.close();
                canvas.drawPath(path, paint);
                
                paint.style = PaintingStyle.stroke;
                paint.color = isHighlightedMatch ? Colors.yellowAccent : Colors.white;
                paint.strokeWidth = isHighlightedMatch ? 3.0 : 1.0;
                canvas.drawPath(path, paint);
              }
''';

  if (chartCode.contains(packetDrawBlock)) {
     chartCode = chartCode.replaceFirst(packetDrawBlock, newPacketDrawBlock);
     chartFile.writeAsStringSync(chartCode);
     print('Updated chart_widget.dart');
  } else {
     print('Failed to find packetDrawBlock in chart_widget.dart');
  }
}
