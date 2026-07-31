import 'package:image/image.dart' as img;

class ImageCropper {
  ImageCropper._();

  static img.Image cropCenterSquare(
    img.Image sourceImage, {
    int maxSize = 256,
  }) {
    final int cropSize = sourceImage.width < sourceImage.height
        ? sourceImage.width
        : sourceImage.height;

    final int offsetX = (sourceImage.width - cropSize) ~/ 2;
    final int offsetY = (sourceImage.height - cropSize) ~/ 2;

    final img.Image squareImage = img.copyCrop(
      sourceImage,
      x: offsetX,
      y: offsetY,
      width: cropSize,
      height: cropSize,
    );

    if (squareImage.width <= maxSize) {
      return squareImage;
    }

    return img.copyResize(
      squareImage,
      width: maxSize,
      height: maxSize,
      interpolation: img.Interpolation.average,
    );
  }
}
