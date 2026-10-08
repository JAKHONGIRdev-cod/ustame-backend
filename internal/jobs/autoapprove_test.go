package jobs

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

type fakeRow struct {
	n   int
	err error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*dest[0].(*int) = r.n
	return nil
}

type fakeDB struct {
	calls atomic.Int32
	n     int
	err   error
}

func (f *fakeDB) QueryRow(_ context.Context, sql string, _ ...any) pgx.Row {
	f.calls.Add(1)
	if sql != `select public.auto_approve_overdue()` {
		return fakeRow{err: errors.New("kutilmagan so'rov: " + sql)}
	}
	return fakeRow{n: f.n, err: f.err}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(time.Second); !cond(); {
		if time.Now().After(deadline) {
			t.Fatal("kutilgan holatga yetmadi")
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func TestAutoApproveRunsOnStartAndIdleTick(t *testing.T) {
	db := &fakeDB{}
	var notified atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		AutoApprove(ctx, db, nil, time.Hour, 20*time.Millisecond, func() { notified.Add(1) })
		close(done)
	}()

	waitFor(t, func() bool { return db.calls.Load() >= 3 })
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ctx bekor bo'lgach to'xtashi kerak edi")
	}
	// Ishga tushishda hech narsa yakunlanmadi — xabar yo'q; har zaxira ishda esa ishchilar uyg'otiladi
	if notified.Load() < 2 {
		t.Fatalf("zaxira ishdan keyin ishchilar uyg'otilishi kerak edi: %d", notified.Load())
	}
}

func TestAutoApproveActivityRespectsMinGap(t *testing.T) {
	db := &fakeDB{}
	activity := make(chan struct{}, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go AutoApprove(ctx, db, activity, 50*time.Millisecond, time.Hour, nil)

	waitFor(t, func() bool { return db.calls.Load() == 1 }) // ishga tushishda
	activity <- struct{}{}                                  // juda tez — o'tkazib yuboriladi
	time.Sleep(20 * time.Millisecond)
	if c := db.calls.Load(); c != 1 {
		t.Fatalf("minGap ichidagi signal bazani uyg'otmasligi kerak: chaqiruvlar %d", c)
	}
	time.Sleep(50 * time.Millisecond)
	activity <- struct{}{} // minGap o'tdi — ishlaydi
	waitFor(t, func() bool { return db.calls.Load() == 2 })
}

func TestAutoApproveNotifiesWhenContractsCompleted(t *testing.T) {
	db := &fakeDB{n: 2}
	var notified atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go AutoApprove(ctx, db, nil, time.Hour, time.Hour, func() { notified.Add(1) })
	waitFor(t, func() bool { return notified.Load() == 1 })
}

func TestAutoApproveSurvivesErrors(t *testing.T) {
	db := &fakeDB{err: errors.New("baza vaqtincha ishlamayapti")}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	AutoApprove(ctx, db, nil, time.Hour, 15*time.Millisecond, nil) // panic qilmasdan, xatoda ham davom etishi kerak
	if db.calls.Load() < 2 {
		t.Fatalf("xatodan keyin ham qayta urinishi kerak edi: %d", db.calls.Load())
	}
}
