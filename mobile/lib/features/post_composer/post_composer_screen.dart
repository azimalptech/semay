import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/auth_service.dart';
import '../../services/posts_service.dart';
import '../../services/stories_service.dart';

enum _ComposeMode { post, story }

class PostComposerScreen extends ConsumerStatefulWidget {
  const PostComposerScreen({super.key});

  @override
  ConsumerState<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends ConsumerState<PostComposerScreen> {
  final _picker = ImagePicker();
  _ComposeMode _mode = _ComposeMode.post;
  bool _submitting = false;

  // Post state
  String _postType = 'image';
  final List<File> _postFiles = [];
  final _captionController = TextEditingController();

  // Story state
  String _storyMediaType = 'image';
  File? _storyFile;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickForPost() async {
    if (_postType == 'reel') {
      final video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video != null) setState(() => _postFiles..clear()..add(File(video.path)));
    } else if (_postType == 'carousel') {
      final images = await _picker.pickMultiImage();
      if (images.isNotEmpty) {
        setState(() => _postFiles..clear()..addAll(images.map((x) => File(x.path))));
      }
    } else {
      final image = await _picker.pickImage(source: ImageSource.gallery);
      if (image != null) setState(() => _postFiles..clear()..add(File(image.path)));
    }
  }

  Future<void> _pickForStory() async {
    if (_storyMediaType == 'video') {
      final video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video != null) setState(() => _storyFile = File(video.path));
    } else {
      final image = await _picker.pickImage(source: ImageSource.gallery);
      if (image != null) setState(() => _storyFile = File(image.path));
    }
  }

  Future<void> _submit() async {
    final storeIds = await ref.read(storeIdsProvider.future);
    if (storeIds.isEmpty) {
      _showError('No store assigned to this account yet');
      return;
    }
    final storeId = storeIds.first;

    setState(() => _submitting = true);
    try {
      if (_mode == _ComposeMode.post) {
        if (_postFiles.isEmpty) {
          _showError('Pick media first');
          return;
        }
        await ref.read(postsServiceProvider).createPost(
              storeId: storeId,
              type: _postType,
              files: _postFiles,
              caption: _captionController.text.trim(),
            );
      } else {
        if (_storyFile == null) {
          _showError('Pick media first');
          return;
        }
        await ref.read(storiesServiceProvider).createStory(
              storeId: storeId,
              mediaFile: _storyFile!,
              mediaType: _storyMediaType,
            );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Post')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_ComposeMode>(
              segments: const [
                ButtonSegment(value: _ComposeMode.post, label: Text('Post')),
                ButtonSegment(value: _ComposeMode.story, label: Text('Story')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _mode == _ComposeMode.post ? _buildPostForm() : _buildStoryForm(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator())
                  : Text(_mode == _ComposeMode.post ? 'Post' : 'Post story'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostForm() {
    return ListView(
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'image', label: Text('Image')),
            ButtonSegment(value: 'carousel', label: Text('Carousel')),
            ButtonSegment(value: 'reel', label: Text('Reel')),
          ],
          selected: {_postType},
          onSelectionChanged: (s) => setState(() {
            _postType = s.first;
            _postFiles.clear();
          }),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(_postFiles.isEmpty ? 'Pick media' : '${_postFiles.length} file(s) selected'),
          onPressed: _pickForPost,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _captionController,
          decoration: const InputDecoration(labelText: 'Caption'),
          maxLines: 3,
        ),
      ],
    );
  }

  Widget _buildStoryForm() {
    return ListView(
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'image', label: Text('Image')),
            ButtonSegment(value: 'video', label: Text('Video')),
          ],
          selected: {_storyMediaType},
          onSelectionChanged: (s) => setState(() {
            _storyMediaType = s.first;
            _storyFile = null;
          }),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(_storyFile == null ? 'Pick media' : '1 file selected'),
          onPressed: _pickForStory,
        ),
      ],
    );
  }
}
