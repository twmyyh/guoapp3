import 'package:duanju_app/pinyin_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pinyinInitials 取每个汉字声母并清掉非字母数字', () {
    expect(pinyinInitials('复仇者联盟'), 'fczlm');
    expect(pinyinInitials('斗罗大陆'), 'dldl');
    // 英文与数字原样保留并小写。
    expect(pinyinInitials('A123'), 'a123');
    // 空格、标点、阿拉伯数字里的数字被规整：数字保留、空白去掉。
    expect(pinyinInitials('流浪地球2'), 'lldq2');
    expect(pinyinInitials('庆余年 第二季'), 'qyndej');
  });

  test('isPinyinInitialsQuery 只认纯字母数字输入', () {
    expect(isPinyinInitialsQuery('fczlm'), isTrue);
    expect(isPinyinInitialsQuery('a1b2'), isTrue);
    expect(isPinyinInitialsQuery('f'), isTrue);
    // 只要含一个中文字符就不是首字母查询。
    expect(isPinyinInitialsQuery('复仇'), isFalse);
    expect(isPinyinInitialsQuery('fczlm复仇'), isFalse);
    expect(isPinyinInitialsQuery(''), isFalse);
    expect(isPinyinInitialsQuery('   '), isFalse);
  });

  test('matchPinyinInitials 命中拼音首字母以输入开头的标题', () {
    const titles = ['复仇者联盟', '斗罗大陆', '赘婿', '庆余年第二季', '流浪地球2', '藏海花'];
    // 全拼首字母精确命中。
    expect(matchPinyinInitials('fczlm', titles), contains('复仇者联盟'));
    expect(matchPinyinInitials('dldl', titles), contains('斗罗大陆'));
    // 单个声母命中一组：f 命中所有 f 开头的剧（此表里只有复仇者联盟）。
    final f = matchPinyinInitials('f', titles);
    expect(f, contains('复仇者联盟'));
    // d 命中斗罗大陆；c 命中藏海花（chah）。
    expect(matchPinyinInitials('d', titles), contains('斗罗大陆'));
    expect(matchPinyinInitials('c', titles), contains('藏海花'));
    // 上限 10，且不包含空查询结果。
    expect(f.length, greaterThan(0));
    expect(f.length, lessThanOrEqualTo(10));
    // 无命中。
    expect(matchPinyinInitials('zzz', titles), isEmpty);
    // 空查询 / 无标题都不崩。
    expect(matchPinyinInitials('', titles), isEmpty);
    expect(matchPinyinInitials('f', const []), isEmpty);
  });
}
