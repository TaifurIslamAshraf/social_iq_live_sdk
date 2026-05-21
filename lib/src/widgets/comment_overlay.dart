import 'package:flutter/material.dart';
import '../models/live_config.dart';
import '../theme/sdk_theme.dart';

/// Scrolling comment overlay for live streams.
/// Shows comments floating at the bottom of the screen with
/// auto-scroll and fade-out effect.
///
/// When [isHost] is true and either [onReply] or [onPin] is provided, a
/// long-press on any comment bubble opens a host actions sheet (reply / pin /
/// unpin). Viewers receive only the read-only rendering.
class CommentOverlay extends StatefulWidget {
  final List<LiveComment> comments;
  final double maxHeight;

  /// Long-press menu visibility is gated on this flag — even if callbacks are
  /// wired, viewers never see the actions.
  final bool isHost;
  final void Function(LiveComment)? onReply;
  final void Function(LiveComment)? onPin;
  final VoidCallback? onUnpin;

  const CommentOverlay({
    super.key,
    required this.comments,
    this.maxHeight = 250,
    this.isHost = false,
    this.onReply,
    this.onPin,
    this.onUnpin,
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

  void _showHostActions(BuildContext context, LiveComment comment) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SdkTheme.backgroundDark,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(SdkTheme.radiusLarge)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor:
                          SdkTheme.primaryPink.withValues(alpha: 0.3),
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
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(comment.userName,
                              style: SdkTheme.commentName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(comment.message,
                              style: SdkTheme.commentText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              if (widget.onReply != null)
                ListTile(
                  leading: const Icon(Icons.reply, color: Colors.white),
                  title: const Text('Reply',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onReply!(comment);
                  },
                ),
              if (!comment.isPinned && widget.onPin != null)
                ListTile(
                  leading: const Icon(Icons.push_pin, color: Colors.white),
                  title: const Text('Pin comment',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onPin!(comment);
                  },
                ),
              if (comment.isPinned && widget.onUnpin != null)
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined,
                      color: Colors.white),
                  title: const Text('Unpin comment',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onUnpin!();
                  },
                ),
            ],
          ),
        );
      },
    );
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
            final comment = widget.comments[index];
            return _CommentBubble(
              comment: comment,
              onLongPress: widget.isHost &&
                      (widget.onReply != null ||
                          widget.onPin != null ||
                          widget.onUnpin != null)
                  ? () => _showHostActions(context, comment)
                  : null,
            );
          },
        ),
      ),
    );
  }
}

class _CommentBubble extends StatelessWidget {
  final LiveComment comment;
  final VoidCallback? onLongPress;

  const _CommentBubble({required this.comment, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final pinned = comment.isPinned;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            // Pinned bubbles get a faint pink tint so the host can spot them.
            color: pinned
                ? SdkTheme.primaryPink.withValues(alpha: 0.25)
                : Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(SdkTheme.radiusLarge),
            border: pinned
                ? Border.all(
                    color: SdkTheme.primaryPink.withValues(alpha: 0.6),
                    width: 1)
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            comment.userName,
                            style: SdkTheme.commentName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (pinned) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.push_pin,
                              size: 12, color: Colors.white70),
                        ],
                      ],
                    ),
                    if (comment.replyToUserName != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '↪ @${comment.replyToUserName}',
                        style: SdkTheme.commentText.copyWith(
                          color: Colors.white70,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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
      ),
    );
  }
}

/// Banner displayed at the top of the host/viewer screen when a comment is
/// pinned. Tap-to-dismiss is host-only via [onUnpin].
class PinnedCommentBanner extends StatelessWidget {
  final LiveComment comment;
  final VoidCallback? onUnpin;

  const PinnedCommentBanner({
    super.key,
    required this.comment,
    this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(SdkTheme.radiusMedium),
        border: Border.all(
            color: SdkTheme.primaryPink.withValues(alpha: 0.8), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.push_pin, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.userName,
                  style: SdkTheme.commentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  comment.message,
                  style: SdkTheme.commentText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onUnpin != null)
            GestureDetector(
              onTap: onUnpin,
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.close, color: Colors.white70, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

/// Comment input field for live streams.
///
/// When [replyingTo] is non-null, a small banner above the field shows
/// `Replying to @name` with a close affordance that fires [onCancelReply].
class CommentInput extends StatefulWidget {
  final ValueChanged<String> onSubmit;
  final String hintText;
  final LiveComment? replyingTo;
  final VoidCallback? onCancelReply;

  const CommentInput({
    super.key,
    required this.onSubmit,
    this.hintText = 'Say something...',
    this.replyingTo,
    this.onCancelReply,
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
    final reply = widget.replyingTo;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reply != null)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(SdkTheme.radiusMedium),
              border: Border.all(
                color: SdkTheme.primaryPink.withValues(alpha: 0.6),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.reply, color: Colors.white70, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Replying to @${reply.userName}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: widget.onCancelReply,
                  child: const Icon(Icons.close,
                      color: Colors.white70, size: 16),
                ),
              ],
            ),
          ),
        Container(
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
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 4),
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
                  child: const Icon(Icons.send_rounded,
                      color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
