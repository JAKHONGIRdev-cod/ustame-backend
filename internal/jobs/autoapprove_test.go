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
	err   error
}

func (f *fakeDB) QueryRow(_ context.Context, sql string, _ ...any) pgx.Row {
	f.calls.Add(1)
	if sql != `select public.auto_approve_overdue()` {
		return fakeRow{err: errors.New("kutilmagan so'rov: " + sql)}
	}
	return fakeRow{n: 2, err: f.err}
}

func TestAutoApproveRunsNowAndOnTick(t *testing.T) {
	db := &fakeDB{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { AutoApprove(ctx, db, 20*time.Millisecond); close(done) }()

	time.Sleep(70 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ctx bekor bo'lgach to'xtashi kerak edi")
	}
	if c := db.calls.Load(); c < 3 {
		t.Fatalf("chaqiruvlar = %d: darhol bir marta va har tick'da ishlashi kerak", c)
	}
}

func TestAutoApproveSurvivesErrors(t *testing.T) {
	db := &fakeDB{err: errors.New("baza vaqtincha ishlamayapti")}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	AutoApprove(ctx, db, 15*time.Millisecond) // panic qilmasdan, xatoda ham davom etishi kerak
	if db.calls.Load() < 2 {
		t.Fatalf("xatodan keyin ham qayta urinishi kerak edi: %d", db.calls.Load())
	}
}
