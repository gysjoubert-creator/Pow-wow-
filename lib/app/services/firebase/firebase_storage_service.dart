import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:pow_wow/app/utils/image_cropper.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class FirebaseStorageService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  User? get firebaseUser => _auth.currentUser;
  String? get uid => firebaseUser?.uid;

  Future<String> uploadAvatar({required File file}) async {
    final String? currentUid = uid;
    if (currentUid == null) {
      throw Exception('User is not authorized');
    }

    final Uint8List bytes = await file.readAsBytes();
    final img.Image? originalImage = img.decodeImage(bytes);

    if (originalImage == null) {
      throw Exception('Failed to decode image');
    }

    final img.Image croppedImage = ImageCropper.cropCenterSquare(
      originalImage,
      maxSize: 250,
    );

    final Directory tempDir = await getTemporaryDirectory();
    final File tempFile = File('${tempDir.path}/avatar_$currentUid.jpg');

    await tempFile.writeAsBytes(img.encodeJpg(croppedImage, quality: 90));

    final Reference ref = _storage.ref().child('avatars/$currentUid.jpg');

    await ref.putFile(tempFile);

    return await ref.getDownloadURL();
  }

  Future<void> deleteAvatar() async {
    final String? currentUid = uid;
    if (currentUid == null) {
      throw Exception('User is not authorized');
    }

    final Reference ref = _storage.ref().child('avatars/$currentUid.jpg');

    try {
      await ref.delete();
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') {
        return;
      }
      rethrow;
    }
  }
}
