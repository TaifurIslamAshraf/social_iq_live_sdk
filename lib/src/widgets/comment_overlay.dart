import 'package:flutter/material.dart';
import '../models/live_config.dart';
import '../theme/sdk_theme.dart';

/// Scrolling comment overlay for live streams.
/// Shows comments floating at the bottom of the screen with
/// auto-scroll and fade-out effect.
class CommentOverlay extends StatefulWidget {
  final List<LiveComment> comments;
  final double maxHeight;

  const CommentOverlay({
    super.key,
    required this.comments,
    this.maxHeight = 250,
  });

  @override
  State<CommentOverlay> createState() => _CommentOverlayState();
}

class _CommentOverlayState extends State<CommentOverlay> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(CommentOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Scroll on new comments OR on any rebuild triggered by unrelated state
    // changes (e.g. mic/camera toggle) so the latest comment stays visible.
    if (widget.comments.isNotEmpty) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) {
        return const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [Colors.transparent, Colors.white],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: ListView.builder(
          controller: _scrollController,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          itemCount: widget.comments.length,
          itemBuilder: (context, index) {
            return _CommentBubble(comment: widget.comments[index]);
          },
        ),
      ),
    );
  }
}

class _CommentBubble extends StatelessWidget {
  final LiveComment comment;

  const _CommentBubble({required this.comment});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(SdkTheme.radiusLarge),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Avatar
            CircleAvatar(
              radius: 14,
              backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
              backgroundImage: comment.userAvatar != null
                  ? NetworkImage(comment.userAvatar!)
                  : null,
              child: comment.userAvatar == null
                  ? Text(
                      comment.userName.isNotEmpty
                          ? comment.userName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            // Name + message
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comment.userName,
                    style: SdkTheme.commentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    comment.message,
                    style: SdkTheme.commentText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comment input field for live streams.
class CommentInput extends StatefulWidget {
  final ValueChanged<String> onSubmit;
  final String hintText;

  const CommentInput({
    super.key,
    required this.onSubmit,
    this.hintText = 'Say something...',
  });

  @override
  State<CommentInput> createState() => _CommentInputState();
}

class _CommentInputState extends State<CommentInput> {
  final TextEditingController _controller = TextEditingController();

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      widget.onSubmit(text);
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SdkTheme.radiusXL),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
            ),
          ),
          GestureDetector(
            onTap: _submit,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: SdkTheme.primaryRed,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}
