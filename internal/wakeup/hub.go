// Package wakeup — jarayon ichidagi "bazada yangi ish bor" signali.
//
// Neon bepul tarifida baza 5 daqiqa tinch tursa uxlaydi va oylik hisoblash soatlari tejaladi.
// Bildirishnoma ishchilari bazani har necha soniyada so'rab tursa, baza hech qachon uxlamaydi va
// oylik limit oy o'rtasida tugaydi. Shuning uchun API yozuvdan keyin Notify qiladi, ishchilar esa
// shu signalni (va kamdan-kam zaxira tekshiruvni) kutadi.
package wakeup

import "sync"

// Hub — bir nechta tinglovchiga signal tarqatadi. Nol qiymati ishlatishga tayyor; nil Hub ham xavfsiz
// (Notify hech narsa qilmaydi, Subscribe hech qachon signal bermaydigan kanal qaytaradi).
type Hub struct {
	mu   sync.Mutex
	subs []chan struct{}
}

// Subscribe — signal keladigan kanal. Kanal 1 o'rinli: tinglovchi band paytida kelgan bir nechta
// signal bittaga qo'shiladi (keyingi tekshiruv baribir hammasini oladi).
func (h *Hub) Subscribe() <-chan struct{} {
	if h == nil {
		return nil
	}
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	h.subs = append(h.subs, ch)
	h.mu.Unlock()
	return ch
}

// Notify — barcha tinglovchilarga signal; hech qachon bloklanmaydi.
func (h *Hub) Notify() {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, ch := range h.subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}
