package wakeup

import "testing"

func TestNotifyReachesAllAndCoalesces(t *testing.T) {
	var h Hub
	a, b := h.Subscribe(), h.Subscribe()
	h.Notify()
	h.Notify() // ikkinchisi birinchisiga qo'shiladi, bloklanmaydi
	for _, ch := range []<-chan struct{}{a, b} {
		select {
		case <-ch:
		default:
			t.Fatal("signal kelmadi")
		}
		select {
		case <-ch:
			t.Fatal("ikki signal bittaga qo'shilishi kerak edi")
		default:
		}
	}
}

func TestNilHubIsSafe(t *testing.T) {
	var h *Hub
	h.Notify()
	if h.Subscribe() != nil {
		t.Fatal("nil Hub nil kanal qaytarishi kerak")
	}
}
