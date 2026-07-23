import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_icon.dart';
import '../../core/image_crop.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/firestore_service.dart';
import '../../services/storage_service.dart';

class EditStoreScreen extends ConsumerStatefulWidget {
  const EditStoreScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<EditStoreScreen> createState() => _EditStoreScreenState();
}

class _EditStoreScreenState extends ConsumerState<EditStoreScreen> {
  final _nameController = TextEditingController();
  final _taglineController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  bool _uploadingAvatar = false;
  String? _avatarUrl;

  @override
  void dispose() {
    _nameController.dispose();
    _taglineController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _loadFrom(Map<String, dynamic> data) {
    if (_loaded) return;
    _nameController.text = data['name'] as String? ?? '';
    _taglineController.text = data['tagline'] as String? ?? '';
    _addressController.text = data['address'] as String? ?? '';
    _phoneController.text = data['phone'] as String? ?? '';
    _avatarUrl = data['avatarUrl'] as String?;
    _loaded = true;
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    final image = await cropSquare(picked);
    if (image == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final bytes = await image.readAsBytes();
      final ref0 = ref
          .read(storageProvider)
          .ref('stores/${widget.storeId}/avatar.jpg');
      await ref0.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref0.getDownloadURL();
      setState(() => _avatarUrl = url);
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ref
        .read(firestoreProvider)
        .collection('stores')
        .doc(widget.storeId)
        .update({
          'name': _nameController.text.trim(),
          'tagline': _taglineController.text.trim(),
          'address': _addressController.text.trim(),
          'phone': _phoneController.text.trim(),
          if (_avatarUrl != null) 'avatarUrl': _avatarUrl,
        });
    if (mounted) Navigator.of(context).pop();
  }

  InputDecoration _pillDecoration([String? hint]) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: AppColors.backgroundCard,
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        title: Text(s.editProfile),
      ),
      body: StreamBuilder<Map<String, dynamic>?>(
        stream: ref
            .watch(firestoreProvider)
            .collection('stores')
            .doc(widget.storeId)
            .snapshots()
            .map((s) => s.data()),
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          _loadFrom(data);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: GestureDetector(
                  onTap: _uploadingAvatar ? null : _pickAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 44,
                        backgroundColor: AppColors.backgroundCard,
                        backgroundImage: (_avatarUrl?.isNotEmpty ?? false)
                            ? CachedNetworkImageProvider(_avatarUrl!)
                            : null,
                        child: (_avatarUrl?.isNotEmpty ?? false)
                            ? null
                            : AppIcon(
                                'image',
                                color: AppColors.textMuted,
                                size: 32,
                              ),
                      ),
                      if (_uploadingAvatar)
                        const Positioned.fill(
                          child: CircleAvatar(
                            backgroundColor: Colors.black38,
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        )
                      else
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: AppColors.brand,
                            child: const AppIcon(
                              'plus',
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(s.storeName, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _nameController,
                style: AppTypography.bodyMedium,
                decoration: _pillDecoration(),
              ),
              const SizedBox(height: 16),
              Text(s.shortDescription, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _taglineController,
                style: AppTypography.bodyMedium,
                maxLength: 120,
                maxLines: 3,
                decoration: _pillDecoration(),
              ),
              const SizedBox(height: 16),
              Text(s.address, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _addressController,
                style: AppTypography.bodyMedium,
                decoration: _pillDecoration(),
              ),
              const SizedBox(height: 16),
              Text(s.phoneNumber, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _phoneController,
                style: AppTypography.bodyMedium,
                keyboardType: TextInputType.phone,
                decoration: _pillDecoration('+993 6X XXXXXX'),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(s.save),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
