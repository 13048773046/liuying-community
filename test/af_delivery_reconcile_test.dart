import 'package:community_app/pages/home/af_workbench_page.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _file(int i, {String url = '', String name = ''}) => {
  'url': url,
  'file': name.isEmpty ? '/work/f$i.html' : name,
  'size': 100 + i,
  'kind': 'html',
};

void main() {
  test('done.files 为空或非列表时不补任何卡', () {
    expect(afDeliveryFileTools(null, const []), isEmpty);
    expect(afDeliveryFileTools(const [], const []), isEmpty);
    expect(afDeliveryFileTools('oops', const []), isEmpty);
  });

  test('无 url 的脏数据被丢弃，正常文件补成 publish_file', () {
    final got = afDeliveryFileTools([
      _file(1),
      _file(2, url: 'https://cdn/x.html', name: '/work/x.html'),
    ], const []);
    expect(got, hasLength(1));
    expect(got.single['name'], 'publish_file');
    expect(got.single['status'], 'ok');
    expect(got.single['args'], {'path': '/work/x.html'});
    expect((got.single['detail'] as Map)['url'], 'https://cdn/x.html');
  });

  test('已由 tool 事件画过的 url 不重复补', () {
    final got = afDeliveryFileTools(
      [
        _file(1, url: 'https://cdn/a.html', name: '/work/a.html'),
        _file(2, url: 'https://cdn/b.html', name: '/work/b.html'),
      ],
      const ['https://cdn/a.html'],
    );
    expect(got, hasLength(1));
    expect((got.single['detail'] as Map)['url'], 'https://cdn/b.html');
  });

  test('同一批重复 url 只补一次，id 唯一', () {
    final got = afDeliveryFileTools([
      _file(1, url: 'https://cdn/a.html', name: '/work/a.html'),
      _file(2, url: 'https://cdn/a.html', name: '/work/a.html'),
    ], const []);
    expect(got, hasLength(1));
    final a = afDeliveryFileTools([
      _file(3, url: 'https://cdn/c.html'),
    ], const []);
    expect(a.single['id'], isNotEmpty);
  });
}
