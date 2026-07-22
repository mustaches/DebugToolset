import 'package:flutter/material.dart';

/// Whether a wizard section is ready or still needs attention.
enum SectionStatus { ok, attention }

/// A collapsible, numbered configuration card used in the font extractor
/// workbench. The header always shows the step number, title, a one-line
/// summary of the current configuration and a status mark, so the whole
/// setup is visible at a glance even when cards are collapsed.
class SectionCard extends StatefulWidget {
  /// 1-based step number shown in the header badge.
  final int number;
  final String title;

  /// One-line summary of the section's current configuration.
  final String summary;
  final SectionStatus status;
  final Widget child;

  const SectionCard({
    super.key,
    required this.number,
    required this.title,
    required this.summary,
    required this.status,
    required this.child,
  });

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final attention = widget.status == SectionStatus.attention;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(
          color: attention ? Colors.orange.shade800 : Colors.grey.shade800,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: attention
                          ? const Color(0xFF4A3A00)
                          : const Color(0xFF0A4A5A),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '${widget.number}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.summary,
                      style: TextStyle(
                        fontSize: 10,
                        color: attention
                            ? Colors.orangeAccent
                            : Colors.grey,
                        fontFamily: 'Consolas',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    attention ? Icons.warning_amber : Icons.check_circle,
                    size: 14,
                    color: attention ? Colors.orangeAccent : Colors.green,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: Colors.grey.shade800),
            Padding(
              padding: const EdgeInsets.all(10),
              child: widget.child,
            ),
          ],
        ],
      ),
    );
  }
}
