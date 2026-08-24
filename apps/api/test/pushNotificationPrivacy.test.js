const { buildFirebaseMessage } = require('../src/lib/firebasePush');

const input = {
  token: 'device-token',
  title: 'Private project review rejected',
  message: 'Sensitive feature at a precise site needs correction.',
  notificationId: '00000000-0000-4000-8000-000000000001',
};

describe('push notification privacy', () => {
  test('uses a generic lock-screen notification and authenticated identifier by default', () => {
    const payload = buildFirebaseMessage(input);

    expect(payload.message.notification).toEqual({
      title: 'TerraLeb',
      body: 'You have a new TerraLeb notification. Open the app to view it securely.',
    });
    expect(payload.message.data).toEqual({
      notificationId: input.notificationId,
      route: '/app/notifications',
      previewMode: 'private',
    });
    expect(JSON.stringify(payload)).not.toContain(input.title);
    expect(JSON.stringify(payload)).not.toContain(input.message);
  });

  test('includes details only after an explicit sensitive-preview preference', () => {
    const payload = buildFirebaseMessage({ ...input, showSensitivePreview: true });

    expect(payload.message.notification.title).toBe(input.title);
    expect(payload.message.notification.body).toBe(input.message);
    expect(payload.message.data.previewMode).toBe('detailed');
  });
});
