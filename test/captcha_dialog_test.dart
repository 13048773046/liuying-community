import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/api/client.dart';

void main() {
  test('Cap token is sent as cap_token and takes precedence', () {
    const answer = CaptchaAnswer.cap(capToken: 'cap-token-123');
    expect(answer.isCap, isTrue);
    expect(answer.toBody(), {'cap_token': 'cap-token-123'});
  });

  test('legacy slider and Tencent payloads remain compatible', () {
    const slider = CaptchaAnswer.slider(id: 'slider-1', x: 123.5, y: 40);
    expect(slider.toBody(), {
      'captcha_id': 'slider-1',
      'captcha_x': 123.5,
      'captcha_y': 40,
    });

    const tencent = CaptchaAnswer.tencent(ticket: 'ticket', randstr: 'rand');
    expect(tencent.toBody(), {
      'captcha_ticket': 'ticket',
      'captcha_randstr': 'rand',
    });
  });
}
