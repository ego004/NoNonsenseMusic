// A cover asked for at the size it is drawn: the server sends the largest (#27).
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/cover_image.dart';

void main() {
  test('a Google image is asked for at the drawn size', () {
    expect(sizedImage('https://lh3.googleusercontent.com/AbC=w1200-h1200-l90-rj', 132), 'https://lh3.googleusercontent.com/AbC=w132-h132-l90-rj');
    expect(sizedImage('https://yt3.ggpht.com/AbC=s1200-c-k-c0x00ffffff-no-rj-mo', 300), 'https://yt3.ggpht.com/AbC=s300-c-k-c0x00ffffff-no-rj-mo');
  });

  test('a JioSaavn image is 150 px for small covers, else 500 px (its only sizes)', () {
    expect(sizedImage('https://c.saavncdn.com/123/Tadipaar-500x500.jpg', 96), 'https://c.saavncdn.com/123/Tadipaar-150x150.jpg');
    expect(sizedImage('https://c.saavncdn.com/123/Tadipaar-500x500.jpg', 900), 'https://c.saavncdn.com/123/Tadipaar-500x500.jpg');
  });

  test('a URL that names no size is kept', () {
    expect(sizedImage('https://i.ytimg.com/vi/abc/hq720.jpg', 300), 'https://i.ytimg.com/vi/abc/hq720.jpg');
  });
}
