const {
  resolveProjectScheduleForMutation,
  todayIsoDate,
} = require('../src/lib/projectLifecycle');

describe('project lifecycle database-date consistency', () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  test('uses the UTC calendar date used by the deployment database near local midnight', () => {
    jest.useFakeTimers().setSystemTime(new Date('2026-08-11T22:30:00.000Z'));

    expect(todayIsoDate()).toBe('2026-08-11');
    expect(
      resolveProjectScheduleForMutation({
        currentStatus: 'draft',
        nextStatus: 'active',
        currentStartDate: null,
        currentEndDate: null,
        startDateProvided: false,
        endDateProvided: false,
      }),
    ).toEqual({ startDate: '2026-08-11', endDate: null });
  });
});
